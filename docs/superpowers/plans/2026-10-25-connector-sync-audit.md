# Connector Sync Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each connector sync records what it did (entries fetched, new and already known, by kind; the new entries; its HTTP calls; its log lines; the stacktrace of a crash), and the Sync History of a source opens on that detail run by run.

**Architecture:** A `SyncTrace` module holds a trace in the worker's process dictionary for the duration of a run; a Finch telemetry handler and a `:logger` handler, both running in the calling process, append HTTP calls and log lines to it. The worker adds counts and new entries (an insert with `RETURNING`), and stores summary counts as `sync_logs` columns plus the bulky part as a JSON `details` column, pruned to the 50 most recent runs. A new endpoint serves one run's details; the frontend moves the history into a `SyncHistory` component whose rows expand on a `SyncRunDetails` panel.

**Tech Stack:** Elixir/Phoenix (Ecto on SQLite, `:telemetry`, `:logger`, OpenApiSpex), Vue 3 + TypeScript (vitest, @vue/test-utils).

**Spec:** `docs/superpowers/specs/2026-10-25-connector-sync-audit-design.md`

## Global Constraints

- Never write em dashes anywhere: code, comments, docs, commit messages. Use a comma, colon, parentheses or a plain hyphen.
- Elixir: `@moduledoc` right after `defmodule`, directives ordered `use`, `import`, `require`, `alias` (alphabetical); no single-pipe expressions; predicates end in `?`; `@spec` under `@doc`; in tests `assert actual == expected`.
- Generate migrations with `mix ecto.gen.migration <name>`, never by hand.
- Vue: multi-word component names, typed `defineProps<{...}>()`, `:key` on every `v-for`, `scoped` styles, SFC order `<script>` then `<template>` then `<style>`; design tokens (`var(--danger)`, `var(--font-mono)`, `var(--text-sm)`), never literal colors, font stacks or font sizes; no font size under `--text-sm`; no single-letter names (except loop index `i` and comparator `(a, b)`); derive in computeds, not in the template.
- Import order in `<script setup>`: framework, then components, then app modules sorted by path, then `import type` last.
- Logs in tests: the test level is `:warning` (`config/test.exs`), so a line a test wants traced is a `Logger.warning`.
- Run `mix format` after Elixir edits, `cd frontend && npm run format` after frontend edits, `mix precommit` at the end.
- Commit messages: `<area>: <lowercase summary>`, ending with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

---

## File structure

| File | Responsibility |
|------|----------------|
| `priv/repo/migrations/<ts>_add_trace_to_sync_logs.exs` (create) | counts columns, `details`, backfill `fetched_count` |
| `lib/servant/connectors/sync_log.ex` (modify) | new fields |
| `lib/servant/audit/log_event.ex` (create) | `:logger` event time and message as text, shared |
| `lib/servant/audit/error_log_handler.ex` (modify) | use `LogEvent` |
| `lib/servant/connectors/sync_trace.ex` (create) | the trace, its two handlers, `summary/2` |
| `lib/servant/application.ex` (modify) | `SyncTrace.attach/0` at boot |
| `lib/servant/data.ex` (modify) | `create_entries_sampled/3` |
| `lib/servant/connectors.ex` (modify) | close runs with counts and details, prune, list summaries, `get_sync_log!/2`, `insert_run_entries/2`, import path |
| `lib/servant/connectors/worker.ex` (modify) | traced run, crash stacktrace |
| `test/support/fake_connector.ex` (modify) | optional log line and external id |
| `lib/servant_web/controllers/connector_controller.ex` (modify) | richer list, `log` action, OpenAPI |
| `lib/servant_web/router.ex` (modify) | `GET /connectors/:id/logs/:log_id` |
| `frontend/src/types.ts` (modify) | `SyncLog` fields, `SyncLogDetails` |
| `frontend/src/api/connectors.ts` (modify) | `connectorLogDetails` |
| `frontend/src/composables/useCopyFeedback.ts` (create) | copy with a "Copied" moment |
| `frontend/src/lib/entryRoute.ts` (modify) | accept `{ id, kind }` |
| `frontend/src/components/SyncRunDetails.vue` (create) | the sections of one run |
| `frontend/src/components/SyncHistory.vue` (create) | the run list, expand, details cache |
| `frontend/src/views/ConnectorDetailView.vue` (modify) | use `SyncHistory` |
| `lib/mix/tasks/servant.seed.ex` (modify) | demo runs carry counts and details |

---

### Task 1: `sync_logs` columns

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_trace_to_sync_logs.exs`
- Modify: `lib/servant/connectors/sync_log.ex`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration add_trace_to_sync_logs`
Expected: `* creating priv/repo/migrations/<timestamp>_add_trace_to_sync_logs.exs`

- [ ] **Step 2: Write it**

```elixir
defmodule Servant.Repo.Migrations.AddTraceToSyncLogs do
  use Ecto.Migration

  # What a sync run did, beside its status: the entries the connector
  # returned (entries_count stays the new ones), how many HTTP calls and log
  # lines it made, and their detail (kept on the most recent runs only).
  def up do
    alter table(:sync_logs) do
      add :fetched_count, :integer, null: false, default: 0
      add :http_count, :integer, null: false, default: 0
      add :http_failed_count, :integer, null: false, default: 0
      add :log_count, :integer, null: false, default: 0
      add :details, :map
    end

    # Older runs only counted what they inserted: that is all they fetched,
    # as far as anyone knows.
    execute "UPDATE sync_logs SET fetched_count = entries_count"
  end

  def down do
    alter table(:sync_logs) do
      remove :fetched_count
      remove :http_count
      remove :http_failed_count
      remove :log_count
      remove :details
    end
  end
end
```

- [ ] **Step 3: The schema**

In `lib/servant/connectors/sync_log.ex`, replace the moduledoc and the schema fields and cast list:

```elixir
  @moduledoc """
  One row per connector sync run (or file import): status, counts, error.
  `entries_count` is the new entries, `fetched_count` all the entries the
  connector returned. `details` holds what the run did (see
  `Servant.Connectors.SyncTrace`); only the most recent runs keep it.
  """
```

```elixir
  schema "sync_logs" do
    field :status, :string
    field :entries_count, :integer, default: 0
    field :fetched_count, :integer, default: 0
    field :http_count, :integer, default: 0
    field :http_failed_count, :integer, default: 0
    field :log_count, :integer, default: 0
    field :details, :map
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :connector_config, Servant.Connectors.ConnectorConfig

    timestamps(type: :utc_datetime)
  end

  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [
      :connector_config_id,
      :status,
      :entries_count,
      :fetched_count,
      :http_count,
      :http_failed_count,
      :log_count,
      :details,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:connector_config_id, :status, :started_at])
    |> validate_inclusion(:status, ~w(running completed failed))
  end
```

- [ ] **Step 4: Migrate and run the connector tests**

Run: `mix ecto.migrate && mix test test/servant/connectors`
Expected: migration runs; all tests pass (nothing reads the new fields yet).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/*_add_trace_to_sync_logs.exs lib/servant/connectors/sync_log.ex
git commit -m "connectors: sync logs gain counts and a details column"
```

---

### Task 2: Shared `:logger` event formatting

`SyncTrace` needs the same "event to text" as `Audit.ErrorLogHandler`. Move it to a module both use.

**Files:**
- Create: `lib/servant/audit/log_event.ex`
- Modify: `lib/servant/audit/error_log_handler.ex`
- Test: `test/servant/audit/error_log_handler_test.exs` (unchanged, the safety net)

- [ ] **Step 1: Create `LogEvent`**

```elixir
defmodule Servant.Audit.LogEvent do
  @moduledoc """
  A `:logger` event as text: its time in ISO 8601 and its message as a
  string, whatever form the message took (string, report, format and
  arguments). Shared by the `:logger` handlers
  (`Servant.Audit.ErrorLogHandler`, `Servant.Connectors.SyncTrace`).
  """

  @doc "The time of the event, ISO 8601; now when the event carries none."
  @spec time(map()) :: String.t()
  def time(%{time: us}) when is_integer(us) do
    us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  def time(_meta), do: DateTime.to_iso8601(DateTime.utc_now())

  @doc "The message of the event as a string."
  @spec message(term(), map()) :: String.t()
  def message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  def message({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {fmt, args} = cb.(report)
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  def message({:report, report}, _meta), do: inspect(report)

  def message({fmt, args}, _meta) when is_list(args) do
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  def message(other, _meta), do: inspect(other)
end
```

- [ ] **Step 2: Use it in `ErrorLogHandler`**

Add `alias Servant.Audit.LogEvent` under the moduledoc, change the entry to:

```elixir
    entry = %{
      at: LogEvent.time(meta),
      level: Atom.to_string(level),
      message: msg |> LogEvent.message(meta) |> String.slice(0, @max_message_length)
    }
```

and delete the private `event_time/1` and `format_message/2` clauses.

- [ ] **Step 3: Run the handler tests**

Run: `mix test test/servant/audit`
Expected: PASS, unchanged.

- [ ] **Step 4: Commit**

```bash
git add lib/servant/audit/log_event.ex lib/servant/audit/error_log_handler.ex
git commit -m "audit: share the log event formatting"
```

---

### Task 3: `SyncTrace`

**Files:**
- Create: `lib/servant/connectors/sync_trace.ex`
- Modify: `lib/servant/application.ex`
- Test: `test/servant/connectors/sync_trace_test.exs`

- [ ] **Step 1: Write the failing tests**

`Req.Test` answers without Finch, so the tests replay the events a real call emits.

```elixir
defmodule Servant.Connectors.SyncTraceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Servant.Connectors.SyncTrace

  # The two events Finch emits for one call, in the calling process.
  defp finch_call(status, result \\ {:ok, :response}) do
    request = Finch.build(:get, "https://api.example.com/v1/items?page=2&api_key=secret")

    if status do
      :telemetry.execute([:finch, :recv, :stop], %{duration: 0}, %{
        request: request,
        status: status,
        headers: []
      })
    end

    :telemetry.execute(
      [:finch, :request, :stop],
      %{duration: System.convert_time_unit(42, :millisecond, :native)},
      %{request: request, result: result}
    )
  end

  test "records a call with its status, never the query string" do
    SyncTrace.start()
    finch_call(200)
    trace = SyncTrace.finish()

    assert trace.http == [
             %{method: "GET", host: "api.example.com", path: "/v1/items", status: 200, ms: 42}
           ]

    refute inspect(trace) =~ "secret"
  end

  test "records a request that failed before any response" do
    SyncTrace.start()
    finch_call(nil, {:error, %RuntimeError{message: "connection refused"}})

    assert [%{status: nil, error: "connection refused"}] = SyncTrace.finish().http
  end

  test "records the lines logged during the run" do
    SyncTrace.start()
    capture_log(fn -> Logger.warning("page 3 of 7") end)

    assert [%{level: "warning", message: "page 3 of 7", at: at}] = SyncTrace.finish().logs
    assert {:ok, _, _} = DateTime.from_iso8601(at)
  end

  test "records nothing outside a trace" do
    finch_call(200)
    capture_log(fn -> Logger.warning("before the run") end)

    refute SyncTrace.active?()
    SyncTrace.start()
    assert %{http: [], logs: []} = SyncTrace.finish()
  end

  test "another process's calls stay out of the trace" do
    SyncTrace.start()
    Task.await(Task.async(fn -> finch_call(500) end))

    assert SyncTrace.finish().http == []
  end

  test "keeps 100 calls and counts the rest" do
    SyncTrace.start()
    for _ <- 1..105, do: finch_call(200)
    trace = SyncTrace.finish()

    assert length(trace.http) == 100
    assert trace.http_omitted == 5
  end

  test "summary/2 counts calls, failures and lines, and merges the details" do
    SyncTrace.start()
    finch_call(200)
    finch_call(503)
    finch_call(nil, {:error, %RuntimeError{message: "timeout"}})
    capture_log(fn -> Logger.warning("retrying") end)

    summary = SyncTrace.summary(SyncTrace.finish(), %{kinds: %{"note" => 2}})

    assert summary.http_count == 3
    assert summary.http_failed_count == 2
    assert summary.log_count == 1
    assert summary.details.kinds == %{"note" => 2}
    assert length(summary.details.http) == 3
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `mix test test/servant/connectors/sync_trace_test.exs`
Expected: FAIL, `Servant.Connectors.SyncTrace` is undefined.

- [ ] **Step 3: Write the module**

```elixir
defmodule Servant.Connectors.SyncTrace do
  @moduledoc """
  Records what one connector sync does, for its sync log: the HTTP calls it
  makes (Finch telemetry) and the lines it logs (a `:logger` handler).

  The worker opens a trace in its own process dictionary before a run
  (`start/0`) and closes it after (`finish/0`). Both handlers run in the
  process that makes the call or logs the line, so they only ever see the
  trace of that run; outside an open trace, they do nothing.

  A call keeps its method, host, path, status and duration only: the query
  string, the headers and the bodies can carry secrets. Work a connector
  hands to another process (a `Task`) is not traced.
  """

  alias Servant.Audit.LogEvent

  @trace_key {__MODULE__, :trace}
  @status_key {__MODULE__, :status}
  @telemetry_id "servant-sync-trace"
  @logger_id :servant_sync_trace
  @max_http 100
  @max_logs 200
  @max_message_length 2_000

  @type t :: %{
          http: [map()],
          http_omitted: non_neg_integer(),
          logs: [map()],
          logs_omitted: non_neg_integer()
        }

  @doc """
  Attaches the telemetry and `:logger` handlers. Called once at boot; a
  second call is harmless (both report the handler as already there).
  """
  @spec attach() :: :ok
  def attach do
    _ =
      :telemetry.attach_many(
        @telemetry_id,
        [[:finch, :recv, :stop], [:finch, :request, :stop], [:finch, :request, :exception]],
        &__MODULE__.handle_event/4,
        nil
      )

    _ = :logger.add_handler(@logger_id, __MODULE__, %{level: :all})
    :ok
  end

  @doc "Opens a trace in the calling process, replacing any leftover one."
  @spec start() :: :ok
  def start do
    Process.delete(@status_key)
    Process.put(@trace_key, empty())
    :ok
  end

  @doc """
  Closes the trace of the calling process and returns it, calls and lines
  in the order they happened; an empty trace when none was open.
  """
  @spec finish() :: t()
  def finish do
    Process.delete(@status_key)

    case Process.delete(@trace_key) do
      nil -> empty()
      trace -> %{trace | http: Enum.reverse(trace.http), logs: Enum.reverse(trace.logs)}
    end
  end

  @doc "Whether the calling process holds an open trace."
  @spec active?() :: boolean()
  def active?, do: Process.get(@trace_key) != nil

  @doc """
  The counts a sync log keeps as columns, and its `details`: the trace
  merged with what the worker adds (`kinds`, `new_entries`, `stacktrace`).
  """
  @spec summary(t(), map()) :: map()
  def summary(trace, details) do
    %{
      http_count: length(trace.http) + trace.http_omitted,
      http_failed_count: Enum.count(trace.http, &failed_call?/1),
      log_count: length(trace.logs) + trace.logs_omitted,
      details: Map.merge(trace, details)
    }
  end

  defp failed_call?(call), do: Map.has_key?(call, :error) or (call.status || 0) >= 400

  @doc false
  # Telemetry handler. The status comes first, with the response; the
  # request stop then closes the call with its total duration.
  def handle_event([:finch, :recv, :stop], _measurements, metadata, _config) do
    if active?(), do: Process.put(@status_key, metadata[:status])
    :ok
  catch
    _, _ -> :ok
  end

  def handle_event([:finch, :request, event], measurements, %{request: request} = metadata, _config)
      when event in [:stop, :exception] do
    if active?() do
      %{
        method: request.method,
        host: request.host,
        path: request.path,
        status: Process.delete(@status_key),
        ms: System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)
      }
      |> put_error(event, metadata)
      |> record(:http, :http_omitted, @max_http)
    end

    :ok
  catch
    _, _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # `:logger` handler callback, run in the process that logs.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    if active?() do
      record(
        %{
          at: LogEvent.time(meta),
          level: Atom.to_string(level),
          message: msg |> LogEvent.message(meta) |> String.slice(0, @max_message_length)
        },
        :logs,
        :logs_omitted,
        @max_logs
      )
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp empty, do: %{http: [], http_omitted: 0, logs: [], logs_omitted: 0}

  # A request that failed before any response (DNS, TLS, timeout) has no
  # status: the error says why.
  defp put_error(call, :stop, %{result: {:error, error}}),
    do: Map.put(call, :error, error_text(error))

  defp put_error(call, :exception, metadata), do: Map.put(call, :error, error_text(metadata[:reason]))
  defp put_error(call, _event, _metadata), do: call

  defp error_text(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error_text(reason), do: inspect(reason)

  defp record(item, list, omitted, max) do
    trace = Process.get(@trace_key)

    trace =
      if length(Map.fetch!(trace, list)) < max,
        do: Map.update!(trace, list, &[item | &1]),
        else: Map.update!(trace, omitted, &(&1 + 1))

    Process.put(@trace_key, trace)
  end
end
```

- [ ] **Step 4: Attach at boot**

In `lib/servant/application.ex`, inside the `with {:ok, _} = ok <- ...` block, after the `:servant_audit_errors` handler:

```elixir
      # What each connector sync does (its HTTP calls and log lines) goes to
      # its sync log. Idempotent like the handler above.
      :ok = Servant.Connectors.SyncTrace.attach()
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/servant/connectors/sync_trace_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/servant/connectors/sync_trace.ex lib/servant/application.ex test/servant/connectors/sync_trace_test.exs
git commit -m "connectors: SyncTrace records the HTTP calls and log lines of a sync"
```

---

### Task 4: Insert entries and sample the new ones

**Files:**
- Modify: `lib/servant/data.ex:190-227`
- Test: `test/servant/data_test.exs` (in `describe "create_entries/2 batch insert"`)

- [ ] **Step 1: Write the failing test**

```elixir
    test "create_entries_sampled/3 returns up to n of the new rows only", %{user: user} do
      known = %{"kind" => "note", "source" => "bulk", "external_id" => "known", "title" => "Old"}
      assert {:ok, 1} = Data.create_entries(user.id, [known])

      fresh =
        for n <- 1..3,
            do: %{"kind" => "note", "source" => "bulk", "external_id" => "n#{n}", "title" => "New #{n}"}

      assert {:ok, 3, sample} = Data.create_entries_sampled(user.id, [known | fresh], 2)
      assert length(sample) == 2
      assert Enum.all?(sample, &(&1.kind == "note" and &1.title =~ "New" and is_binary(&1.id)))
    end
```

- [ ] **Step 2: Run it to see it fail**

Run: `mix test test/servant/data_test.exs`
Expected: FAIL, `create_entries_sampled/3` is undefined.

- [ ] **Step 3: Implement**

Replace `create_entries/2` (both clauses) with:

```elixir
  def create_entries(user_id, attrs_list) do
    with {:ok, count, _sample} <- create_entries_sampled(user_id, attrs_list, 0),
         do: {:ok, count}
  end

  @doc """
  `create_entries/2`, which also returns up to `sample_size` of the rows it
  inserted, as `%{id, kind, title}`. Those are new entries only: a skipped
  conflict returns no row. The sync logs list them.

  Returns `{:ok, inserted_count, sample}`.
  """
  def create_entries_sampled(_user_id, [], _sample_size), do: {:ok, 0, []}

  def create_entries_sampled(user_id, attrs_list, sample_size) when is_list(attrs_list) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, sample} =
      attrs_list
      |> Stream.map(&entry_row(user_id, &1, now))
      |> Stream.chunk_every(@insert_chunk_size)
      |> Enum.reduce({0, []}, fn rows, {count, sample} ->
        missing = sample_size - length(sample)

        {inserted, returned} =
          Repo.insert_all(Entry, rows,
            on_conflict: :nothing,
            conflict_target: [:user_id, :source, :external_id],
            # Only while the sample is short: a large sync returns no rows.
            returning: if(missing > 0, do: [:id, :kind, :title], else: false)
          )

        new =
          for entry <- Enum.take(returned || [], max(missing, 0)),
              do: %{id: entry.id, kind: entry.kind, title: entry.title}

        {count + inserted, sample ++ new}
      end)

    if count > 0, do: broadcast(user_id, {:entries_changed, %{count: count}})
    {:ok, count, sample}
  end
```

Keep the existing `@doc` of `create_entries/2` above its new head.

- [ ] **Step 4: Run the data tests**

Run: `mix test test/servant/data_test.exs test/servant_web/channels/data_channel_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/servant/data.ex test/servant/data_test.exs
git commit -m "data: create_entries_sampled/3 returns a sample of the new rows"
```

---

### Task 5: The connectors context

**Files:**
- Modify: `lib/servant/connectors.ex` (sync log functions around line 244, `run_import/10`, `list_sync_logs/2`)
- Modify: `test/servant_web/controllers/connector_controller_test.exs:197` (new `complete_sync_log/2` argument)
- Test: `test/servant/connectors/sync_log_test.exs` (create)

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Servant.Connectors.SyncLogTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.SyncLog
  alias Servant.Repo

  setup do
    user = user_fixture()

    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "feed",
        "schedule" => "on_demand"
      })

    %{user: user, config: config}
  end

  test "a run keeps its counts; the list leaves its details out", %{config: config} do
    {:ok, log} = Connectors.create_sync_log(config.id)

    {:ok, _} =
      Connectors.complete_sync_log(log, %{
        entries_count: 2,
        fetched_count: 5,
        http_count: 3,
        http_failed_count: 1,
        log_count: 4,
        details: %{kinds: %{"note" => 5}}
      })

    assert [listed] = Connectors.list_sync_logs(config.id)
    assert listed.status == "completed"
    assert listed.fetched_count == 5
    assert listed.http_failed_count == 1
    assert listed.has_details
    refute Map.has_key?(listed, :details)

    assert Connectors.get_sync_log!(config.id, log.id).details == %{"kinds" => %{"note" => 5}}
  end

  test "details that cannot be stored are dropped, the run still closes", %{config: config} do
    {:ok, log} = Connectors.create_sync_log(config.id)

    assert {:ok, closed} =
             Connectors.fail_sync_log(log, "boom", %{http_count: 2, details: %{bad: {:not, :json}}})

    assert closed.status == "failed"
    assert closed.http_count == 2
    assert Repo.get!(SyncLog, log.id).details == nil
  end

  test "opening a run trims the history of its source", %{config: config} do
    now = DateTime.utc_now(:second)

    rows =
      for i <- 1..505 do
        %{
          id: Ecto.UUID.generate(),
          connector_config_id: config.id,
          status: "completed",
          details: %{"n" => i},
          started_at: DateTime.add(now, -i * 60, :second),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(SyncLog, rows)
    {:ok, _} = Connectors.create_sync_log(config.id)

    runs = where(SyncLog, connector_config_id: ^config.id)
    assert Repo.aggregate(runs, :count) == 500
    # The run just opened is one of the 50 most recent, and has no details yet.
    assert runs |> where([log], not is_nil(log.details)) |> Repo.aggregate(:count) == 49
  end

  test "a run belongs to its source", %{user: user, config: config} do
    {:ok, other} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "other",
        "schedule" => "on_demand"
      })

    {:ok, log} = Connectors.create_sync_log(other.id)
    assert_raise Ecto.NoResultsError, fn -> Connectors.get_sync_log!(config.id, log.id) end
  end

  test "insert_run_entries/2 tells new entries from known ones", %{user: user} do
    entries = [
      %{"kind" => "note", "source" => "feed", "external_id" => "a", "title" => "A"},
      %{"kind" => "photo", "source" => "feed", "external_id" => "b", "title" => "B"}
    ]

    {:ok, 1} = Servant.Data.create_entries(user.id, [hd(entries)])
    {counts, details} = Connectors.insert_run_entries(user.id, entries)

    assert counts == %{entries_count: 1, fetched_count: 2}
    assert details.kinds == %{"note" => 1, "photo" => 1}
    assert [%{title: "B", kind: "photo"}] = details.new_entries
  end
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `mix test test/servant/connectors/sync_log_test.exs`
Expected: FAIL (`complete_sync_log/2` takes a count, `get_sync_log!/2` and `insert_run_entries/2` are undefined).

- [ ] **Step 3: Implement the sync log functions**

Replace `create_sync_log/1`, `complete_sync_log/2` and `fail_sync_log/2` with:

```elixir
  # Run history of a source: the most recent runs stay, and only the most
  # recent of those keep their details (the bulky part).
  @keep_runs 500
  @keep_details 50
  @max_new_entries 20

  @doc "Opens a run (status running) and trims the history of its source."
  def create_sync_log(config_id) do
    result =
      %SyncLog{}
      |> SyncLog.changeset(%{
        connector_config_id: config_id,
        status: "running",
        started_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
      |> Repo.insert()

    with {:ok, _} <- result, do: prune_sync_logs(config_id)
    result
  end

  @doc """
  Closes a run as completed. `summary` holds the counts (`entries_count`,
  the new entries; `fetched_count`; `http_count`, `http_failed_count`,
  `log_count`) and `details` (see `Servant.Connectors.SyncTrace`).
  """
  def complete_sync_log(sync_log, summary) do
    close_sync_log(sync_log, Map.put(summary, :status, "completed"))
  end

  @doc "Closes a run as failed, with its error and the same summary."
  def fail_sync_log(sync_log, error, summary \\ %{}) do
    close_sync_log(sync_log, Map.merge(summary, %{status: "failed", error: to_string(error)}))
  end

  # The details are the bulky, optional part: when they cannot be written
  # (a term JSON cannot encode), the run still records its status and counts.
  defp close_sync_log(sync_log, attrs) do
    attrs = Map.put(attrs, :finished_at, DateTime.truncate(DateTime.utc_now(), :second))

    try do
      sync_log |> SyncLog.changeset(attrs) |> Repo.update()
    rescue
      _ -> sync_log |> SyncLog.changeset(Map.delete(attrs, :details)) |> Repo.update()
    end
  end

  @doc """
  Trims the run history of a source: the #{@keep_runs} most recent runs
  stay, and only the #{@keep_details} most recent keep their details.
  """
  def prune_sync_logs(config_id) do
    runs = where(SyncLog, connector_config_id: ^config_id)

    keep =
      runs
      |> order_by(desc: :started_at, desc: :inserted_at)
      |> limit(@keep_runs)
      |> select([log], log.id)
      |> Repo.all()

    runs |> where([log], log.id not in ^keep) |> Repo.delete_all()

    detailed = Enum.take(keep, @keep_details)

    runs
    |> where([log], log.id not in ^detailed and not is_nil(log.details))
    |> Repo.update_all(set: [details: nil])

    :ok
  end

  @doc """
  Inserts the entries a run returned and says what they brought:
  `{%{entries_count: new, fetched_count: returned}, %{kinds: ..., new_entries: ...}}`.
  The syncs (`Worker`) and the file imports share it.
  """
  def insert_run_entries(user_id, entries) do
    {:ok, inserted, new_entries} =
      Servant.Data.create_entries_sampled(user_id, entries, @max_new_entries)

    {%{entries_count: inserted, fetched_count: length(entries)},
     %{kinds: Enum.frequencies_by(entries, &entry_kind/1), new_entries: new_entries}}
  end

  defp entry_kind(entry), do: Map.get(entry, "kind") || Map.get(entry, :kind) || "unknown"
```

- [ ] **Step 4: List summaries, read one run**

Replace `list_sync_logs/2` with:

```elixir
  # Everything but the bulky details, which one run's page reads on its own.
  @sync_log_summary SyncLog.__schema__(:fields) -- [:details]

  @doc """
  The most recent runs of a source, newest first, as maps without their
  details: `has_details` says whether `get_sync_log!/2` has some.
  """
  def list_sync_logs(config_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SyncLog
    |> where(connector_config_id: ^config_id)
    |> order_by(desc: :started_at, desc: :inserted_at)
    |> limit(^limit)
    |> select([log], map(log, ^@sync_log_summary))
    |> select_merge([log], %{has_details: not is_nil(log.details)})
    |> Repo.all()
  end

  @doc "One run of a source, details included. Raises when it is not that source's."
  def get_sync_log!(config_id, log_id) do
    Repo.get_by!(SyncLog, id: log_id, connector_config_id: config_id)
  end
```

- [ ] **Step 5: The import path**

In `run_import/10`, replace the `{:ok, entries}` branch head:

```elixir
      {:ok, entries} ->
        {counts, details} = insert_run_entries(user_id, entries)
        complete_sync_log(sync_log, Map.put(counts, :details, details))
```

and its result map:

```elixir
        {:ok,
         %{
           imported: counts.entries_count,
           total: length(entries),
           skipped: length(entries) - counts.entries_count,
           file_path: Servant.Storage.public_url(relative)
         }}
```

- [ ] **Step 6: The controller test's call**

In `test/servant_web/controllers/connector_controller_test.exs`, `Connectors.complete_sync_log(log, 3)` becomes `Connectors.complete_sync_log(log, %{entries_count: 3})`.

- [ ] **Step 7: Run the tests**

Run: `mix test test/servant/connectors test/servant_web/controllers/connector_controller_test.exs`
Expected: PASS. The worker still calls `complete_sync_log(sync_log, inserted)` with an integer, which now fails: if `worker_test.exs` breaks here, that is Task 6's work; run Task 6 before committing, or commit with the worker change.

- [ ] **Step 8: Commit** (together with Task 6 if the worker tests failed)

```bash
git add lib/servant/connectors.ex test/servant/connectors/sync_log_test.exs test/servant_web/controllers/connector_controller_test.exs
git commit -m "connectors: runs close with counts and details, history pruned"
```

---

### Task 6: The traced worker

**Files:**
- Modify: `lib/servant/connectors/worker.ex` (`run_sync/2` and below)
- Modify: `test/support/fake_connector.ex`
- Test: `test/servant/connectors/worker_test.exs` (new `describe "sync trace"`)

- [ ] **Step 1: Teach the fake connector to log and to repeat an entry**

In `test/support/fake_connector.ex`: add `require Logger` after `use Servant.Connectors.Connector`; in `init/2` add two keys to the state map:

```elixir
         log: Map.get(config, "log"),
         external_id: Map.get(config, "external_id"),
```

and replace the `sync/1` clauses with:

```elixir
  @impl true
  def sync(%{raise_sync: true} = state) do
    log(state)
    raise "connector blew up"
  end

  def sync(%{fail_sync: message} = state) when is_binary(message) do
    {:error, message, state}
  end

  def sync(%{fail_sync: true} = state) do
    {:error, :sync_failed, state}
  end

  def sync(state) do
    log(state)

    entry = %{
      "kind" => "note",
      "source" => "fake",
      "title" => "synced",
      "external_id" => state.external_id
    }

    {:ok, [entry], %{state | cursor: "advanced"}}
  end

  # A line for the sync trace to pick up (a warning: the test log level).
  defp log(%{log: nil}), do: :ok
  defp log(%{log: line}), do: Logger.warning(line)
```

- [ ] **Step 2: Write the failing tests**

Append to `worker_test.exs`, before `describe "update_connector_config/3"` (they use `start_worker/3`):

```elixir
  describe "sync trace" do
    @describetag :capture_log

    test "a success records what came in and what the connector logged", %{user: user} do
      {config, pid} =
        start_worker(user, %{"config" => %{"external_id" => "fake-1", "log" => "fetched page 1"}})

      for _ <- 1..2 do
        Worker.sync_now(user.id, config.id)
        _ = :sys.get_state(pid)
      end

      logs = Connectors.list_sync_logs(config.id)
      first = Enum.find(logs, &(&1.entries_count == 1))
      second = Enum.find(logs, &(&1.entries_count == 0))

      assert first.fetched_count == 1
      assert second.fetched_count == 1
      assert second.log_count == 1

      details = Connectors.get_sync_log!(config.id, first.id).details
      assert details["kinds"] == %{"note" => 1}
      assert [%{"title" => "synced", "kind" => "note"}] = details["new_entries"]
      assert [%{"level" => "warning", "message" => "fetched page 1"}] = details["logs"]
    end

    test "a raise records the stack trace and the lines before it", %{user: user} do
      {config, pid} =
        start_worker(user, %{"config" => %{"raise_sync" => true, "log" => "about to fail"}})

      Worker.sync_now(user.id, config.id)
      _ = :sys.get_state(pid)

      [log] = Connectors.list_sync_logs(config.id)
      details = Connectors.get_sync_log!(config.id, log.id).details

      assert details["stacktrace"] =~ "connector blew up"
      assert details["stacktrace"] =~ "Servant.FakeConnector.sync/1"
      assert [%{"message" => "about to fail"}] = details["logs"]
    end

    test "the worker's own lines stay out of the trace", %{user: user} do
      {config, pid} = start_worker(user, %{"config" => %{"fail_sync" => "Token refresh failed"}})

      Worker.sync_now(user.id, config.id)
      _ = :sys.get_state(pid)

      # The worker logs "Connector sync error" after the run: not the connector's.
      assert [%{status: "failed", log_count: 0}] = Connectors.list_sync_logs(config.id)
    end
  end
```

- [ ] **Step 3: Run them to see them fail**

Run: `mix test test/servant/connectors/worker_test.exs`
Expected: FAIL (the worker records no fetched count, no details).

- [ ] **Step 4: Rewrite the run in the worker**

In `worker.ex`, add `alias Servant.Connectors.SyncTrace` to the aliases (keep them alphabetical; `Servant.Data` is no longer used there, remove its alias), and replace `run_sync/2` (with its `rescue`) by:

```elixir
  defp run_sync(%__MODULE__{} = state, sync_log) do
    {result, trace} = traced_sync(state)

    try do
      record_run(state, sync_log, result, trace)
    rescue
      # create_entries or a DB write raised after the connector returned.
      # Without this rescue, the worker crashes and the sync_log stays
      # "running" forever.
      e -> crashed(state, sync_log, e, __STACKTRACE__, trace)
    end
  end

  # The connector's own work, traced: the HTTP calls it made and the lines
  # it logged. A raise is caught here, so its trace still reaches the log.
  defp traced_sync(%__MODULE__{} = state) do
    SyncTrace.start()

    result =
      try do
        state.connector_module.sync(state.state)
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      end

    {result, SyncTrace.finish()}
  end

  defp record_run(state, sync_log, {:ok, entries, new_connector_state}, trace) do
    {counts, details} = Connectors.insert_run_entries(state.user_id, entries)
    Connectors.complete_sync_log(sync_log, Map.merge(SyncTrace.summary(trace, details), counts))
    persist_cursor(state, new_connector_state)
    update_sync_status(state.config_id, nil)
    schedule_sync(%{state | state: new_connector_state})
  end

  defp record_run(state, sync_log, {:error, reason, new_connector_state}, trace) do
    message = format_reason(reason)
    Logger.error("Connector sync error [#{sync_context(state)}]: #{message}")
    Connectors.fail_sync_log(sync_log, message, SyncTrace.summary(trace, %{}))
    # Persist the returned state too. A connector possibly rotated a
    # refresh_token before the step that failed. The loss of that token
    # (until the next successful sync) breaks the connector on the next
    # restart.
    persist_cursor(state, new_connector_state)
    update_sync_status(state.config_id, message)
    schedule_sync(%{state | state: new_connector_state})
  end

  defp record_run(state, sync_log, {:raised, exception, stacktrace}, trace) do
    crashed(state, sync_log, exception, stacktrace, trace)
  end

  # Fail the sync_log with the stack trace, arm the timer again, continue.
  defp crashed(state, sync_log, exception, stacktrace, trace) do
    reason = Exception.message(exception)
    Logger.error("Connector sync crashed [#{sync_context(state)}]: #{reason}")

    Connectors.fail_sync_log(
      sync_log,
      reason,
      SyncTrace.summary(trace, %{stacktrace: Exception.format(:error, exception, stacktrace)})
    )

    update_sync_status(state.config_id, reason)
    schedule_sync(state)
  end
```

- [ ] **Step 5: Run the connector suite**

Run: `mix test test/servant/connectors test/servant/data_test.exs`
Expected: PASS, the existing worker tests included.

- [ ] **Step 6: Commit**

```bash
git add lib/servant/connectors/worker.ex test/support/fake_connector.ex test/servant/connectors/worker_test.exs
git commit -m "connectors: the worker traces each sync into its log"
```

---

### Task 7: API

**Files:**
- Modify: `lib/servant_web/controllers/connector_controller.ex` (`operation(:logs ...)`, `logs/2`)
- Modify: `lib/servant_web/router.ex:127`
- Test: `test/servant_web/controllers/connector_controller_test.exs` (`describe "logs"`)

- [ ] **Step 1: Write the failing tests**

Replace the first test of `describe "logs"` and add three:

```elixir
    test "lists the sync logs of a connector", %{conn: conn, user: user} do
      config = create_strava(user.id)
      {:ok, log} = Connectors.create_sync_log(config.id)

      Connectors.complete_sync_log(log, %{
        entries_count: 3,
        fetched_count: 10,
        http_count: 4,
        http_failed_count: 1,
        details: %{kinds: %{"activity" => 10}}
      })

      conn = get(conn, "/api/connectors/#{config.id}/logs")
      assert %{"data" => [entry]} = json_response(conn, 200)
      assert entry["status"] == "completed"
      assert entry["entries_count"] == 3
      assert entry["known_count"] == 7
      assert entry["http_failed_count"] == 1
      assert entry["has_details"] == true
      refute Map.has_key?(entry, "details")
    end

    test "returns one run with its details", %{conn: conn, user: user} do
      config = create_strava(user.id)
      {:ok, log} = Connectors.create_sync_log(config.id)
      Connectors.complete_sync_log(log, %{details: %{kinds: %{"activity" => 10}}})

      conn = get(conn, "/api/connectors/#{config.id}/logs/#{log.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == log.id
      assert data["details"] == %{"kinds" => %{"activity" => 10}}
    end

    test "a run of another source is a 404", %{conn: conn, user: user} do
      config = create_strava(user.id)
      other = create_strava(user.id)
      {:ok, log} = Connectors.create_sync_log(other.id)

      assert_error_sent(404, fn -> get(conn, "/api/connectors/#{config.id}/logs/#{log.id}") end)
    end

    test "cannot read a run of another user", %{conn: conn} do
      foreign = create_strava(user_fixture().id)
      {:ok, log} = Connectors.create_sync_log(foreign.id)

      assert_error_sent(404, fn -> get(conn, "/api/connectors/#{foreign.id}/logs/#{log.id}") end)
    end
```

- [ ] **Step 2: Run them to see them fail**

Run: `mix test test/servant_web/controllers/connector_controller_test.exs`
Expected: FAIL (no `known_count`; no route for one run).

- [ ] **Step 3: The route**

In `router.ex`, after `get "/connectors/:id/logs", ConnectorController, :logs`:

```elixir
        get "/connectors/:id/logs/:log_id", ConnectorController, :log
```

- [ ] **Step 4: The controller**

Above `operation(:logs, ...)`, add the shared schemas:

```elixir
  @sync_log_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      status: %Schema{type: :string, enum: ["running", "completed", "failed"]},
      entries_count: %Schema{type: :integer, description: "New entries inserted by the run"},
      fetched_count: %Schema{type: :integer, description: "Entries the connector returned"},
      known_count: %Schema{type: :integer, description: "Returned entries already stored"},
      http_count: %Schema{type: :integer},
      http_failed_count: %Schema{type: :integer, description: "Status >= 400 or network error"},
      log_count: %Schema{type: :integer},
      has_details: %Schema{type: :boolean},
      error: %Schema{type: :string, nullable: true},
      started_at: %Schema{type: :string, format: :"date-time", nullable: true},
      finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  }

  @sync_log_details_schema %Schema{
    type: :object,
    nullable: true,
    description:
      "What the run did: kinds, new_entries (20 at most), http (method, host, path, " <>
        "status, ms, error), http_omitted, logs (at, level, message), logs_omitted, stacktrace",
    additionalProperties: true
  }
```

In `operation(:logs, ...)`, replace the inline item schema with `items: @sync_log_schema`. Replace `logs/2` with:

```elixir
  def logs(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    # Make sure that the user owns the config.
    _config = Connectors.get_connector_config!(user_id, id)

    json(conn, %{
      data: Enum.map(Connectors.list_sync_logs(id), &sync_log_json(&1, &1.has_details))
    })
  end

  operation(:log,
    summary: "One sync log of a connector, with what the run did",
    description:
      "Session-only. The details are kept on the 50 most recent runs of a connector; " <>
        "an older run returns null details.",
    parameters: [
      id: [in: :path, type: :string, required: true],
      log_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok:
        {"Sync log", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               allOf: [
                 @sync_log_schema,
                 %Schema{type: :object, properties: %{details: @sync_log_details_schema}}
               ]
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def log(conn, %{"id" => id, "log_id" => log_id}) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)
    log = Connectors.get_sync_log!(config.id, log_id)

    json(conn, %{
      data: log |> sync_log_json(not is_nil(log.details)) |> Map.put(:details, log.details)
    })
  end

  defp sync_log_json(log, has_details) do
    %{
      id: log.id,
      status: log.status,
      entries_count: log.entries_count,
      fetched_count: log.fetched_count,
      known_count: max(log.fetched_count - log.entries_count, 0),
      http_count: log.http_count,
      http_failed_count: log.http_failed_count,
      log_count: log.log_count,
      has_details: has_details,
      error: log.error,
      started_at: log.started_at,
      finished_at: log.finished_at
    }
  end
```

Copy the `unauthorized`/`forbidden`/`not_found` lines of `operation(:logs, ...)` if their wording differs.

- [ ] **Step 5: Run the web tests**

Run: `mix test test/servant_web`
Expected: PASS, `openapi_test.exs` included.

- [ ] **Step 6: Commit**

```bash
git add lib/servant_web/controllers/connector_controller.ex lib/servant_web/router.ex test/servant_web/controllers/connector_controller_test.exs
git commit -m "api: sync log summaries, and one run with its details"
```

---

### Task 8: Frontend plumbing

**Files:**
- Modify: `frontend/src/types.ts:104-111`
- Modify: `frontend/src/api/connectors.ts`
- Create: `frontend/src/composables/useCopyFeedback.ts`
- Modify: `frontend/src/lib/entryRoute.ts:5`
- Modify: `frontend/src/views/ConnectorDetailView.vue:53-58`

- [ ] **Step 1: Types**

Replace `SyncLog` in `types.ts` and add the details types after it:

```ts
export interface SyncLog {
  id: string
  status: 'running' | 'completed' | 'failed'
  // The new entries; known_count = fetched_count - entries_count
  entries_count: number
  fetched_count: number
  known_count: number
  http_count: number
  http_failed_count: number
  log_count: number
  has_details: boolean
  error: string | null
  started_at: string
  finished_at: string | null
}

// What one run did (GET /api/connectors/:id/logs/:log_id), kept on the 50
// most recent runs of a source
export interface SyncLogDetails {
  kinds?: Record<string, number>
  new_entries?: { id: string; kind: string; title: string | null }[]
  http?: SyncHttpCall[]
  http_omitted?: number
  logs?: SyncLogLine[]
  logs_omitted?: number
  stacktrace?: string
}

export interface SyncHttpCall {
  method: string
  host: string
  path: string
  status: number | null
  ms: number
  error?: string
}

export interface SyncLogLine {
  at: string
  level: string
  message: string
}
```

- [ ] **Step 2: API call**

In `api/connectors.ts`, add `SyncLogDetails` to the type import, and after `connectorLogs`:

```ts
// null when the run is older than the 50 whose details are kept
export async function connectorLogDetails(
  id: string,
  logId: string
): Promise<SyncLogDetails | null> {
  const res = await apiJson<{ data: { details: SyncLogDetails | null } }>(
    'GET',
    `/api/connectors/${id}/logs/${logId}`
  )
  return res.data.details
}
```

- [ ] **Step 3: `useCopyFeedback`**

```ts
import { ref } from 'vue'

// Copies to the clipboard and remembers what was copied for a moment, so
// the button that did it can say "Copied".
export function useCopyFeedback(delay = 1500) {
  const copiedId = ref<string | null>(null)

  function copy(text: string, id: string) {
    void navigator.clipboard.writeText(text)
    copiedId.value = id
    setTimeout(() => {
      if (copiedId.value === id) copiedId.value = null
    }, delay)
  }

  return { copiedId, copy }
}
```

In `ConnectorDetailView.vue`, replace the local `copiedId` ref and `copyError` function (lines 53-58) with:

```ts
const { copiedId, copy: copyError } = useCopyFeedback()
```

and import it after `useConfirm`: `import { useCopyFeedback } from '../composables/useCopyFeedback'`.

- [ ] **Step 4: `entryRoute` takes an id and a kind**

In `lib/entryRoute.ts`: `export function entryRoute(e: Pick<Entry, 'id' | 'kind'>): string {`.

- [ ] **Step 5: Check and commit**

Run: `cd frontend && npx vue-tsc -b && npx vitest run src/lib`
Expected: no type error, tests pass.

```bash
git add frontend/src/types.ts frontend/src/api/connectors.ts frontend/src/composables/useCopyFeedback.ts frontend/src/lib/entryRoute.ts frontend/src/views/ConnectorDetailView.vue
git commit -m "frontend: sync log details types, API call, copy feedback composable"
```

---

### Task 9: `SyncHistory` and `SyncRunDetails`

**Files:**
- Create: `frontend/src/components/SyncRunDetails.vue`
- Create: `frontend/src/components/SyncHistory.vue`
- Modify: `frontend/src/views/ConnectorDetailView.vue` (template lines 604-650, `duration`, log styles)
- Test: `frontend/src/components/SyncHistory.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, RouterLinkStub } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import SyncHistory from './SyncHistory.vue'

import { connectorLogDetails } from '../api/connectors'
import type { SyncLog } from '../types'

vi.mock('../api/connectors', () => ({ connectorLogDetails: vi.fn() }))

function run(overrides: Partial<SyncLog> = {}): SyncLog {
  return {
    id: 'run-1',
    status: 'completed',
    entries_count: 12,
    fetched_count: 152,
    known_count: 140,
    http_count: 37,
    http_failed_count: 2,
    log_count: 3,
    has_details: true,
    error: null,
    started_at: '2026-10-25T10:00:00Z',
    finished_at: '2026-10-25T10:00:03Z',
    ...overrides
  }
}

function mountHistory(logs: SyncLog[]) {
  return mount(SyncHistory, {
    props: { connectorId: 'source-1', logs },
    global: { stubs: { RouterLink: RouterLinkStub } }
  })
}

describe('SyncHistory', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(connectorLogDetails).mockReset()
  })

  it('sums up a run in one line', () => {
    const wrapper = mountHistory([run()])
    expect(wrapper.text()).toContain('12 new · 140 already known')
    expect(wrapper.text()).toContain('2 of 37 calls failed')
  })

  it('loads the details once and shows only the sections with content', async () => {
    vi.mocked(connectorLogDetails).mockResolvedValue({
      kinds: { bank_tx: 152 },
      new_entries: [{ id: 'e1', kind: 'bank_tx', title: 'Coffee' }],
      http: [],
      logs: []
    })
    const wrapper = mountHistory([run()])
    const toggle = wrapper.get('button[aria-expanded]')

    await toggle.trigger('click')
    await flushPromises()
    expect(toggle.attributes('aria-expanded')).toBe('true')
    expect(wrapper.text()).toContain('Coffee')
    expect(wrapper.text()).toContain('Bank transactions')
    expect(wrapper.text()).not.toContain('HTTP calls')

    await toggle.trigger('click')
    await toggle.trigger('click')
    await flushPromises()
    expect(connectorLogDetails).toHaveBeenCalledTimes(1)
  })

  it('says when a run kept no details', async () => {
    vi.mocked(connectorLogDetails).mockResolvedValue(null)
    const wrapper = mountHistory([run()])

    await wrapper.get('button[aria-expanded]').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain('Details are kept for the 50 most recent runs.')
  })

  it('does not expand a running sync', () => {
    const wrapper = mountHistory([run({ status: 'running', finished_at: null })])
    expect(wrapper.find('button[aria-expanded]').exists()).toBe(false)
  })
})
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd frontend && npx vitest run src/components/SyncHistory.test.ts`
Expected: FAIL, `./SyncHistory.vue` does not exist.

- [ ] **Step 3: `SyncRunDetails.vue`**

```vue
<script setup lang="ts">
import { computed } from 'vue'
import { Check, Copy } from 'lucide-vue-next'

import KindIcon from './KindIcon.vue'

import { useCopyFeedback } from '../composables/useCopyFeedback'
import { formatTime } from '../lib/datetime'
import { entryRoute } from '../lib/entryRoute'
import { kindLabel } from '../lib/kind'
import type { SyncLogDetails } from '../types'

// What one sync run did, in the order a reader asks: where it broke, what
// came in, over which calls, and what the connector said along the way.
// Only the sections with something to show render.
const props = defineProps<{
  details: SyncLogDetails
  // New entries of the run: the details list 20 of them at most
  newCount: number
}>()

const { copiedId, copy } = useCopyFeedback()

const newEntries = computed(() =>
  (props.details.new_entries ?? []).map(entry => ({
    id: entry.id,
    kind: entry.kind,
    label: entry.title || 'Untitled',
    to: entryRoute(entry)
  }))
)
const moreNew = computed(() => props.newCount - newEntries.value.length)

const kinds = computed(() =>
  Object.entries(props.details.kinds ?? {})
    .sort((a, b) => b[1] - a[1])
    .map(([kind, count]) => ({ kind, count, label: kindLabel(kind) }))
)

const calls = computed(() =>
  (props.details.http ?? []).map((call, i) => ({
    key: i,
    method: call.method,
    url: `${call.host}${call.path}`,
    status: call.status ?? (call.error ? 'error' : '-'),
    error: call.error,
    failed: Boolean(call.error) || (call.status ?? 0) >= 400,
    duration: `${call.ms} ms`
  }))
)

const lines = computed(() =>
  (props.details.logs ?? []).map((line, i) => ({
    key: i,
    level: line.level,
    message: line.message,
    time: formatTime(line.at, {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    })
  }))
)

const quiet = computed(
  () =>
    !props.details.stacktrace &&
    !newEntries.value.length &&
    !kinds.value.length &&
    !calls.value.length &&
    !lines.value.length
)
</script>

<template>
  <div class="run-details">
    <section v-if="details.stacktrace" class="run-section">
      <h3 class="run-title">Stack trace</h3>
      <details class="run-stack">
        <summary>Show the stack trace</summary>
        <pre>{{ details.stacktrace }}</pre>
      </details>
      <button
        type="button"
        class="small ghost run-copy"
        @click="copy(details.stacktrace ?? '', 'stack')"
      >
        <Check v-if="copiedId === 'stack'" :size="14" />
        <Copy v-else :size="14" />
        {{ copiedId === 'stack' ? 'Copied' : 'Copy the stack trace' }}
      </button>
    </section>

    <section v-if="newEntries.length" class="run-section">
      <h3 class="run-title">New entries</h3>
      <ul class="run-entries">
        <li v-for="entry in newEntries" :key="entry.id">
          <RouterLink :to="entry.to" class="run-entry">
            <KindIcon :kind="entry.kind" :size="14" />
            <span class="run-entry-title">{{ entry.label }}</span>
          </RouterLink>
        </li>
      </ul>
      <p v-if="moreNew > 0" class="run-more">+ {{ moreNew }} more</p>
    </section>

    <section v-if="kinds.length" class="run-section">
      <h3 class="run-title">By kind</h3>
      <ul class="run-kinds">
        <li v-for="item in kinds" :key="item.kind" class="run-kind">
          <KindIcon :kind="item.kind" :size="14" />
          <span>{{ item.label }}</span>
          <span class="run-count">{{ item.count }}</span>
        </li>
      </ul>
    </section>

    <section v-if="calls.length" class="run-section">
      <h3 class="run-title">HTTP calls</h3>
      <div class="table-scroll">
        <table class="run-calls">
          <thead>
            <tr>
              <th>Status</th>
              <th>Method</th>
              <th>Host and path</th>
              <th>Time</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="call in calls"
              :key="call.key"
              :class="{ 'run-call--failed': call.failed }"
            >
              <td>{{ call.status }}</td>
              <td>{{ call.method }}</td>
              <td class="run-call-url">
                {{ call.url }}
                <span v-if="call.error" class="run-call-error">{{
                  call.error
                }}</span>
              </td>
              <td>{{ call.duration }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-if="details.http_omitted" class="run-more">
        + {{ details.http_omitted }} more calls, not kept
      </p>
    </section>

    <section v-if="lines.length" class="run-section">
      <h3 class="run-title">Log</h3>
      <ol class="run-log">
        <li
          v-for="line in lines"
          :key="line.key"
          class="run-line"
          :class="`run-line--${line.level}`"
        >
          <span class="run-line-time">{{ line.time }}</span>
          <span class="run-line-level">{{ line.level }}</span>
          <span class="run-line-message">{{ line.message }}</span>
        </li>
      </ol>
      <p v-if="details.logs_omitted" class="run-more">
        + {{ details.logs_omitted }} more lines, not kept
      </p>
    </section>

    <p v-if="quiet" class="run-more">
      This run made no HTTP call and logged nothing.
    </p>
  </div>
</template>

<style scoped>
.run-details {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 0.75rem 0 0.25rem;
}

.run-title {
  margin: 0 0 0.4rem;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: var(--text-sm);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}

.run-more {
  margin: 0.35rem 0 0;
  font-size: var(--text-sm);
  color: var(--text-muted);
}

/* ----- Stack trace ----- */

.run-stack summary {
  cursor: pointer;
  font-size: var(--text-sm);
  color: var(--text-muted);
}

.run-stack pre {
  margin-top: 0.5rem;
  padding: 0.75rem;
  max-height: 20rem;
  overflow: auto;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  white-space: pre;
}

.run-copy {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  margin-top: 0.5rem;
}

/* ----- New entries and kinds ----- */

.run-entries,
.run-kinds {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.run-entry,
.run-kind {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
}

.run-entry-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.run-count {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  color: var(--text-muted);
}

/* ----- HTTP calls ----- */

.run-calls {
  font-size: var(--text-sm);
}

.run-calls td {
  font-family: var(--font-mono);
  white-space: nowrap;
}

.run-calls .run-call-url {
  white-space: normal;
  word-break: break-all;
}

.run-call-error {
  display: block;
  color: var(--danger);
}

.run-call--failed td:first-child {
  color: var(--danger);
}

/* ----- Log ----- */

.run-log {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

.run-line {
  display: flex;
  gap: 0.75rem;
}

.run-line-time,
.run-line-level {
  flex-shrink: 0;
  color: var(--text-muted);
}

.run-line-message {
  min-width: 0;
  overflow-wrap: anywhere;
}

.run-line--warning .run-line-level {
  color: var(--warning);
}

.run-line--error .run-line-level,
.run-line--critical .run-line-level {
  color: var(--danger);
}
</style>
```

- [ ] **Step 4: `SyncHistory.vue`**

```vue
<script setup lang="ts">
import { computed, ref } from 'vue'
import { Check, ChevronRight, Copy, LoaderCircle, X } from 'lucide-vue-next'

import SyncRunDetails from './SyncRunDetails.vue'

import { connectorLogDetails } from '../api/connectors'
import { useCopyFeedback } from '../composables/useCopyFeedback'
import { relativeTime } from '../lib/datetime'
import type { SyncLog, SyncLogDetails } from '../types'

// The run history of a source, one row per sync or file import. A finished
// row opens on what the run did (SyncRunDetails), fetched the first time it
// opens, then kept.
const props = defineProps<{
  connectorId: string
  logs: SyncLog[]
}>()

type DetailState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'ready'; details: SyncLogDetails | null }

const opened = ref(new Set<string>())
const loaded = ref(new Map<string, DetailState>())
const { copiedId, copy } = useCopyFeedback()

const rows = computed(() =>
  props.logs.map(log => ({
    log,
    expandable: log.status !== 'running',
    open: opened.value.has(log.id),
    outcome: outcome(log),
    callsFailed: log.http_failed_count
      ? `${log.http_failed_count} of ${log.http_count} calls failed`
      : '',
    when: relativeTime(log.started_at),
    duration: duration(log),
    detail: loaded.value.get(log.id)
  }))
)

// "12 new · 140 already known"; a failed run that brought nothing says it
// in its error instead
function outcome(log: SyncLog): string {
  if (log.status === 'running') return ''
  if (log.status === 'failed' && !log.fetched_count) return ''
  const parts = [log.entries_count ? `${log.entries_count} new` : 'Nothing new']
  if (log.known_count) parts.push(`${log.known_count} already known`)
  return parts.join(' · ')
}

function duration(log: SyncLog): string {
  if (!log.finished_at) return '-'
  const ms =
    new Date(log.finished_at).getTime() - new Date(log.started_at).getTime()
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60000).toFixed(1)}m`
}

async function toggle(log: SyncLog) {
  if (opened.value.has(log.id)) {
    opened.value.delete(log.id)
    return
  }
  opened.value.add(log.id)
  const known = loaded.value.get(log.id)
  if (known && known.status !== 'error') return

  loaded.value.set(log.id, { status: 'loading' })
  try {
    const details = await connectorLogDetails(props.connectorId, log.id)
    loaded.value.set(log.id, { status: 'ready', details })
  } catch {
    loaded.value.set(log.id, { status: 'error' })
  }
}
</script>

<template>
  <ul class="sync-history">
    <li v-for="row in rows" :key="row.log.id" class="sync-run">
      <div class="sync-run-head">
        <span
          class="sync-run-icon"
          :class="`sync-run-icon--${row.log.status}`"
          aria-hidden="true"
        >
          <Check v-if="row.log.status === 'completed'" :size="14" />
          <X v-else-if="row.log.status === 'failed'" :size="14" />
          <LoaderCircle v-else :size="14" class="sync-run-spin" />
        </span>
        <button
          v-if="row.expandable"
          type="button"
          class="sync-run-toggle"
          :aria-expanded="row.open"
          :aria-controls="`sync-run-${row.log.id}`"
          @click="toggle(row.log)"
        >
          <span class="sync-run-status">{{ row.log.status }}</span>
          <span v-if="row.outcome" class="sync-run-outcome">{{
            row.outcome
          }}</span>
          <span v-if="row.callsFailed" class="sync-run-badge">{{
            row.callsFailed
          }}</span>
          <ChevronRight :size="16" class="sync-run-chevron" />
        </button>
        <span v-else class="sync-run-status">{{ row.log.status }}</span>
        <span class="sync-run-time">
          <span>{{ row.when }}</span>
          <span>{{ row.duration }}</span>
        </span>
      </div>

      <p v-if="row.log.error" class="sync-run-error">
        <span class="sync-run-error-text">{{ row.log.error }}</span>
        <button
          type="button"
          class="sync-run-copy"
          :title="copiedId === row.log.id ? 'Copied!' : 'Copy error'"
          :aria-label="copiedId === row.log.id ? 'Copied' : 'Copy error'"
          @click="copy(row.log.error ?? '', row.log.id)"
        >
          <Check v-if="copiedId === row.log.id" :size="14" />
          <Copy v-else :size="14" />
        </button>
      </p>

      <div
        v-if="row.open"
        :id="`sync-run-${row.log.id}`"
        class="sync-run-details"
      >
        <p
          v-if="!row.detail || row.detail.status === 'loading'"
          class="sync-run-note"
        >
          Loading...
        </p>
        <p v-else-if="row.detail.status === 'error'" class="sync-run-note">
          The details of this run could not be loaded.
        </p>
        <SyncRunDetails
          v-else-if="row.detail.details"
          :details="row.detail.details"
          :new-count="row.log.entries_count"
        />
        <p v-else class="sync-run-note">
          Details are kept for the 50 most recent runs.
        </p>
      </div>
    </li>
  </ul>
</template>

<style scoped>
.sync-history {
  list-style: none;
  display: flex;
  flex-direction: column;
}

.sync-run {
  padding: 0.6rem 0;
  border-bottom: 1px solid var(--border);
}

.sync-run:last-child {
  border-bottom: none;
}

/* ----- Row ----- */

.sync-run-head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.sync-run-icon {
  width: 26px;
  height: 26px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.sync-run-icon--completed {
  background: color-mix(in srgb, var(--success) 15%, transparent);
  color: var(--success);
}

.sync-run-icon--failed {
  background: color-mix(in srgb, var(--danger) 15%, transparent);
  color: var(--danger);
}

.sync-run-icon--running {
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
}

.sync-run-spin {
  animation: sync-run-spin 1.2s linear infinite;
}

@keyframes sync-run-spin {
  to {
    transform: rotate(360deg);
  }
}

/* A plain row, not a painted button: the text and the chevron say it
   opens; hover and focus change the color only */
.sync-run-toggle {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.25rem 0.75rem;
  padding: 0.25rem 0;
  background: transparent;
  border: none;
  border-radius: 0;
  color: var(--text);
  text-align: left;
}

.sync-run-toggle:hover {
  background: transparent;
  color: var(--text);
}

.sync-run-status {
  font-weight: 500;
  text-transform: capitalize;
}

.sync-run-outcome {
  font-size: var(--text-sm);
  color: var(--text-muted);
}

.sync-run-badge {
  font-size: var(--text-sm);
  color: var(--danger);
}

.sync-run-chevron {
  margin-left: auto;
  color: var(--text-muted);
  transition: transform 0.15s;
}

.sync-run-toggle[aria-expanded='true'] .sync-run-chevron {
  transform: rotate(90deg);
}

.sync-run-time {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  font-size: var(--text-sm);
  color: var(--text-muted);
  white-space: nowrap;
}

/* ----- Error ----- */

.sync-run-error {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  min-width: 0;
  margin: 0.25rem 0 0 calc(26px + 0.75rem);
}

.sync-run-error-text {
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  color: var(--danger);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sync-run-copy {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 24px;
  height: 24px;
  padding: 0;
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
}

.sync-run-copy:hover {
  background: transparent;
  border-color: var(--primary);
  color: var(--primary);
}

/* ----- Details ----- */

.sync-run-details {
  margin-left: calc(26px + 0.75rem);
}

.sync-run-note {
  padding-top: 0.5rem;
  font-size: var(--text-sm);
  color: var(--text-muted);
}
</style>
```

- [ ] **Step 5: Run the test**

Run: `cd frontend && npx vitest run src/components/SyncHistory.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Use it in `ConnectorDetailView.vue`**

Import it with the other components: `import SyncHistory from '../components/SyncHistory.vue'`. In the template, replace the whole `<div v-else-if="logs.length" class="log-list"> ... </div>` block (the `v-for="log in logs"` rows) with:

```vue
          <SyncHistory
            v-else-if="logs.length"
            :connector-id="connectorId"
            :logs="logs"
          />
```

Then delete the now unused `duration` function, the `LoaderCircle` and `X` icon imports, and the `/* Log list */` styles (`.log-list` to `.log-duration`); keep `.spin` (the sync button uses it) and `.refresh-btn`.

- [ ] **Step 7: Check and commit**

Run: `cd frontend && npm run format && npx vue-tsc -b && npx vitest run`
Expected: no type error (no unused import left), all tests pass.

```bash
git add frontend/src/components/SyncHistory.vue frontend/src/components/SyncRunDetails.vue frontend/src/components/SyncHistory.test.ts frontend/src/views/ConnectorDetailView.vue
git commit -m "connectors: the sync history opens on what each run did"
```

---

### Task 10: Demo data and wrap-up

**Files:**
- Modify: `lib/mix/tasks/servant.seed.ex` (`seed_sync_logs/2`)
- Modify: `frontend/README.md` (components line)

- [ ] **Step 1: Seed runs that show the feature**

In `seed_sync_logs/2`, give each run counts, and the most recent one details. Replace the changeset map with:

```elixir
      fetched = if failed, do: 0, else: 20 + :rand.uniform(80)
      new = if failed, do: 0, else: :rand.uniform(12)

      %SyncLog{}
      |> SyncLog.changeset(%{
        connector_config_id: connector.id,
        status: if(failed, do: "failed", else: "completed"),
        entries_count: new,
        fetched_count: fetched,
        http_count: 3,
        http_failed_count: if(failed, do: 1, else: 0),
        log_count: 2,
        details: if(day == 0, do: seed_run_details(connector, fetched)),
        error: if(failed, do: "Rate limit exceeded, retrying later"),
        started_at: started,
        finished_at: DateTime.add(started, 2 + :rand.uniform(20), :second)
      })
      |> Repo.insert!()
```

and add:

```elixir
  # What the latest run of a source did, so the history has one to open
  defp seed_run_details(connector, fetched) do
    host = connector.connector_type <> ".example.com"

    %{
      kinds: %{"activity" => fetched},
      new_entries: [],
      http: [
        %{method: "GET", host: host, path: "/api/v1/items", status: 200, ms: 182},
        %{method: "GET", host: host, path: "/api/v1/items", status: 200, ms: 164},
        %{method: "GET", host: host, path: "/api/v1/me", status: 200, ms: 91}
      ],
      http_omitted: 0,
      logs: [
        %{at: DateTime.to_iso8601(DateTime.utc_now()), level: "info", message: "page 1 of 2"},
        %{at: DateTime.to_iso8601(DateTime.utc_now()), level: "info", message: "page 2 of 2"}
      ],
      logs_omitted: 0
    }
  end
```

- [ ] **Step 2: README line**

In `frontend/README.md`, add `SyncHistory` and `SyncRunDetails` to the `src/components/` line: "..., `CommandPalette`, `SyncHistory` (a source's runs, each opening on `SyncRunDetails`)".

- [ ] **Step 3: Full check**

Run: `mix precommit && cd frontend && npm run format:check && npx vue-tsc -b && npx vitest run`
Expected: all green.

- [ ] **Step 4: See it**

Seed a throwaway database and look at a source's Sync History (desktop and phone width): rows read "N new · M already known", one opens on its calls and log, a failed one shows its stack trace.

```bash
DEV_DB=syncaudit mix servant.seed
DEV_DB=syncaudit PORT=4013 mix phx.server
```

Then trigger a real sync on an RSS source (Sources > a feed > Sync now) and open its run: the HTTP call to the feed and its status should be there.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/servant.seed.ex frontend/README.md
git commit -m "seed: demo runs with counts and details"
```
