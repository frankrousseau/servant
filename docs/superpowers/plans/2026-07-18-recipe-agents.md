# Recipe Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deterministic recurring agents: a strictly validated JSON recipe (where / group_by / aggregate / emit_if) interpreted in Elixir on schedule, drafted once by the LLM, producing `report` entries with zero tokens at run time.

**Architecture:** The existing `agents` table gains a `mode` ("prompt" | "recipe") and a `recipe` map. The run pipeline (`prepare_run` -> execute -> store) branches on mode: recipe runs load the window unpaginated, interpret in memory via a new pure module `Servant.Agents.Recipe`, and store a `kind: "report"` entry with no model in metadata. A `POST /api/agents/draft_recipe` endpoint asks `Servant.AI` to translate a plain-language description into a recipe (one repair retry, run tracked as action "draft_recipe"). Frontend: mode selector in the existing Recurring form, editable JSON textarea, merged ai_report + report lists.

**Tech Stack:** Elixir/Phoenix, Ecto/SQLite (exqlite), Req (+ Req.Test stubs), Vue 3 `<script setup>` TS, existing ComboBox component.

**Spec:** `docs/superpowers/specs/2026-07-18-recipe-agents-design.md`

## Global Constraints

- **Never write em dashes** anywhere (code, comments, UI copy, commit messages). Use `-`, `:`, `;` or parentheses.
- **No commits during execution** (session workflow): tasks end at green tests; commits happen at the end on Frank's explicit request. Ignore per-task commit steps conventions; the final verification task runs `mix precommit`.
- Elixir style per AGENTS.md: `@moduledoc` first, alias alphabetical, no single-pipe expressions, predicate functions end in `?`, no `@spec` (the repo has none, do not add lone ones).
- Tests: `start_supervised!/1`, no `Process.sleep`, actual value left of the operator, monitor + `assert_receive {:DOWN, ...}` for spawned tasks.
- Vue: typed `defineProps`, `:key` on `v-for`, scoped styles, Prettier before done (`cd frontend && npm run format`).
- All new API routes are session-only and behind `ServantWeb.Plugs.RequireAgents` (already the case for the whole AgentController).

---

### Task 1: Recipe module (validate + run)

Pure module, no DB, no HTTP. TDD.

**Files:**
- Create: `lib/servant/agents/recipe.ex`
- Test: `test/servant/agents/recipe_test.exs`

**Interfaces:**
- Consumes: `Servant.Data.Entry` structs (fields used: `title`, `source`, `occurred_at` (DateTime or nil), `data` (map), `metadata` (map)).
- Produces: `Servant.Agents.Recipe.validate(recipe_map) :: :ok | {:error, binary}` and `Servant.Agents.Recipe.run(recipe_map, entries) :: {:ok, markdown_binary} | :skip`. Task 2 calls `validate/1` from the changeset; Task 3 calls `run/2`.

- [ ] **Step 1: Write the failing tests**

Create `test/servant/agents/recipe_test.exs`:

```elixir
defmodule Servant.Agents.RecipeTest do
  use ExUnit.Case, async: true

  alias Servant.Agents.Recipe
  alias Servant.Data.Entry

  defp entry(attrs) do
    struct!(
      %Entry{title: nil, source: "test", occurred_at: nil, data: %{}, metadata: %{}},
      attrs
    )
  end

  defp dt(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  describe "validate/1" do
    test "accepts a full valid recipe" do
      recipe = %{
        "where" => [%{"field" => "data.category", "op" => "eq", "value" => "grocery"}],
        "group_by" => "data.category",
        "aggregate" => %{"op" => "sum", "field" => "data.amount"}
      }

      assert Recipe.validate(recipe) == :ok
    end

    test "accepts an empty recipe (digest of the window)" do
      assert Recipe.validate(%{}) == :ok
    end

    test "rejects non-maps and unknown keys" do
      assert {:error, _} = Recipe.validate("nope")
      assert {:error, message} = Recipe.validate(%{"select" => "x"})
      assert message =~ "unknown"
    end

    test "rejects bad where clauses" do
      assert {:error, _} = Recipe.validate(%{"where" => "not a list"})
      assert {:error, _} = Recipe.validate(%{"where" => [%{"field" => "data.x"}]})

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "password", "op" => "eq", "value" => 1}]
               })

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "explode", "value" => 1}]
               })

      # numeric ops need a numeric value, contains needs a string
      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "gt", "value" => "high"}]
               })

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "contains", "value" => 3}]
               })

      # exists takes no value
      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "exists", "value" => 1}]
               })

      assert Recipe.validate(%{"where" => [%{"field" => "data.x", "op" => "exists"}]}) == :ok
    end

    test "rejects bad group_by and aggregate" do
      assert {:error, _} = Recipe.validate(%{"group_by" => "year"})
      assert Recipe.validate(%{"group_by" => "week"}) == :ok
      assert Recipe.validate(%{"group_by" => "data.category"}) == :ok

      assert {:error, _} = Recipe.validate(%{"aggregate" => %{"op" => "median", "field" => "data.x"}})
      assert {:error, _} = Recipe.validate(%{"aggregate" => %{"op" => "sum"}})
      # count takes no field
      assert {:error, _} = Recipe.validate(%{"aggregate" => %{"op" => "count", "field" => "data.x"}})
      assert Recipe.validate(%{"aggregate" => %{"op" => "count"}}) == :ok
    end

    test "emit_if requires an aggregate and no group_by, numeric value, comparison op" do
      agg = %{"aggregate" => %{"op" => "count"}}

      assert Recipe.validate(Map.put(agg, "emit_if", %{"op" => "eq", "value" => 0})) == :ok
      assert {:error, _} = Recipe.validate(%{"emit_if" => %{"op" => "eq", "value" => 0}})

      assert {:error, _} =
               Recipe.validate(
                 agg
                 |> Map.put("group_by", "data.x")
                 |> Map.put("emit_if", %{"op" => "eq", "value" => 0})
               )

      assert {:error, _} = Recipe.validate(Map.put(agg, "emit_if", %{"op" => "exists", "value" => 0}))
      assert {:error, _} = Recipe.validate(Map.put(agg, "emit_if", %{"op" => "eq", "value" => "zero"}))
    end
  end

  describe "run/2 filtering" do
    test "where conditions AND together; missing fields never match" do
      entries = [
        entry(data: %{"category" => "grocery", "amount" => 10}),
        entry(data: %{"category" => "grocery", "amount" => 3}),
        entry(data: %{"category" => "fuel", "amount" => 50}),
        entry(data: %{"amount" => 99})
      ]

      recipe = %{
        "where" => [
          %{"field" => "data.category", "op" => "eq", "value" => "grocery"},
          %{"field" => "data.amount", "op" => "gte", "value" => 5}
        ],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "1"
    end

    test "contains, neq and exists ops" do
      entries = [
        entry(title: "EDF invoice", data: %{"status" => "paid"}),
        entry(title: "Rent", data: %{})
      ]

      contains = %{
        "where" => [%{"field" => "title", "op" => "contains", "value" => "EDF"}],
        "aggregate" => %{"op" => "count"}
      }

      exists = %{
        "where" => [%{"field" => "data.status", "op" => "exists"}],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, c1} = Recipe.run(contains, entries)
      assert c1 =~ "1"
      assert {:ok, c2} = Recipe.run(exists, entries)
      assert c2 =~ "1"
    end

    test "occurred_at compares chronologically against ISO strings" do
      entries = [
        entry(occurred_at: dt("2026-07-01T00:00:00Z")),
        entry(occurred_at: dt("2026-07-15T00:00:00Z"))
      ]

      recipe = %{
        "where" => [%{"field" => "occurred_at", "op" => "gte", "value" => "2026-07-10"}],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "1"
    end
  end

  describe "run/2 aggregates" do
    test "sum, avg, min, max ignore non-numeric values" do
      entries = [
        entry(data: %{"amount" => 10}),
        entry(data: %{"amount" => 20}),
        entry(data: %{"amount" => "n/a"})
      ]

      assert {:ok, sum} = Recipe.run(%{"aggregate" => %{"op" => "sum", "field" => "data.amount"}}, entries)
      assert sum =~ "30"

      assert {:ok, avg} = Recipe.run(%{"aggregate" => %{"op" => "avg", "field" => "data.amount"}}, entries)
      assert avg =~ "15"

      assert {:ok, min} = Recipe.run(%{"aggregate" => %{"op" => "min", "field" => "data.amount"}}, entries)
      assert min =~ "10"

      assert {:ok, max} = Recipe.run(%{"aggregate" => %{"op" => "max", "field" => "data.amount"}}, entries)
      assert max =~ "20"
    end

    test "last takes the field from the most recent entry that has it" do
      entries = [
        entry(occurred_at: dt("2026-07-15T00:00:00Z"), data: %{}),
        entry(occurred_at: dt("2026-07-10T00:00:00Z"), data: %{"balance" => 1200}),
        entry(occurred_at: dt("2026-07-01T00:00:00Z"), data: %{"balance" => 900})
      ]

      assert {:ok, content} =
               Recipe.run(%{"aggregate" => %{"op" => "last", "field" => "data.balance"}}, entries)

      assert content =~ "1200"
    end

    test "sum over an empty selection is 0; avg reports no data" do
      assert {:ok, sum} = Recipe.run(%{"aggregate" => %{"op" => "sum", "field" => "data.x"}}, [])
      assert sum =~ "0"

      assert {:ok, avg} = Recipe.run(%{"aggregate" => %{"op" => "avg", "field" => "data.x"}}, [])
      assert avg =~ "no data"
    end
  end

  describe "run/2 grouping" do
    test "group by field renders a markdown table sorted by value desc" do
      entries = [
        entry(data: %{"category" => "grocery", "amount" => 10}),
        entry(data: %{"category" => "grocery", "amount" => 5}),
        entry(data: %{"category" => "fuel", "amount" => 50}),
        entry(data: %{"amount" => 1})
      ]

      recipe = %{
        "group_by" => "data.category",
        "aggregate" => %{"op" => "sum", "field" => "data.amount"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "| data.category |"
      # fuel (50) before grocery (15); entries without the group field land under "-"
      {fuel_idx, _} = :binary.match(content, "fuel")
      {grocery_idx, _} = :binary.match(content, "grocery")
      assert fuel_idx < grocery_idx
      assert content =~ "| - |"
    end

    test "time buckets group on occurred_at and sort chronologically" do
      entries = [
        entry(occurred_at: dt("2026-07-15T10:00:00Z"), data: %{"amount" => 2}),
        entry(occurred_at: dt("2026-07-15T18:00:00Z"), data: %{"amount" => 3}),
        entry(occurred_at: dt("2026-06-01T00:00:00Z"), data: %{"amount" => 7})
      ]

      day = %{"group_by" => "day", "aggregate" => %{"op" => "sum", "field" => "data.amount"}}
      month = %{"group_by" => "month", "aggregate" => %{"op" => "sum", "field" => "data.amount"}}
      week = %{"group_by" => "week", "aggregate" => %{"op" => "count"}}

      assert {:ok, by_day} = Recipe.run(day, entries)
      assert by_day =~ "2026-07-15"
      assert by_day =~ "5"

      assert {:ok, by_month} = Recipe.run(month, entries)
      assert by_month =~ "2026-06"
      assert by_month =~ "2026-07"
      # chronological: June row before July row
      {june_idx, _} = :binary.match(by_month, "2026-06")
      {july_idx, _} = :binary.match(by_month, "2026-07")
      assert june_idx < july_idx

      assert {:ok, by_week} = Recipe.run(week, entries)
      assert by_week =~ "2026-W29"
    end

    test "entries without occurred_at are skipped by time buckets" do
      entries = [entry(occurred_at: nil, data: %{"amount" => 5})]
      recipe = %{"group_by" => "day", "aggregate" => %{"op" => "count"}}

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "(no entries)"
    end
  end

  describe "run/2 digest and emit_if" do
    test "no aggregate renders a date | title list" do
      entries = [
        entry(occurred_at: dt("2026-07-18T09:00:00Z"), title: "Standup"),
        entry(occurred_at: nil, title: nil)
      ]

      assert {:ok, content} = Recipe.run(%{}, entries)
      assert content =~ "- 2026-07-18 | Standup"
      assert content =~ "- - | -"
    end

    test "empty digest says so" do
      assert {:ok, content} = Recipe.run(%{}, [])
      assert content =~ "(no entries)"
    end

    test "emit_if true produces content, emit_if false skips" do
      entries = [entry(data: %{})]
      base = %{"aggregate" => %{"op" => "count"}}

      assert {:ok, _} = Recipe.run(Map.put(base, "emit_if", %{"op" => "gte", "value" => 1}), entries)
      assert Recipe.run(Map.put(base, "emit_if", %{"op" => "eq", "value" => 0}), entries) == :skip
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/servant/agents/recipe_test.exs`
Expected: FAIL (module `Servant.Agents.Recipe` is not available).

- [ ] **Step 3: Implement the module**

Create `lib/servant/agents/recipe.ex`:

```elixir
defmodule Servant.Agents.Recipe do
  @moduledoc """
  Declarative recipe for deterministic recurring agents: a fixed-shape,
  strictly validated JSON object (where / group_by / aggregate / emit_if)
  interpreted in memory over the agent's entry window. No model call at
  run time; the LLM only drafts the recipe at authoring time.
  """

  @known_keys ~w(where group_by aggregate emit_if)
  @filter_ops ~w(eq neq contains gt gte lt lte exists)
  @numeric_ops ~w(gt gte lt lte)
  @aggregate_ops ~w(sum avg count min max last)
  @emit_ops ~w(eq neq gt gte lt lte)
  @time_buckets ~w(day week month)
  @field_re ~r/^(title|source|occurred_at|data\.[a-zA-Z0-9_][a-zA-Z0-9_.-]*|metadata\.[a-zA-Z0-9_][a-zA-Z0-9_.-]*)$/

  # ----- validation -----

  def validate(recipe) when is_map(recipe) do
    with :ok <- validate_keys(recipe),
         :ok <- validate_where(Map.get(recipe, "where")),
         :ok <- validate_group_by(Map.get(recipe, "group_by")),
         :ok <- validate_aggregate(Map.get(recipe, "aggregate")) do
      validate_emit_if(Map.get(recipe, "emit_if"), recipe)
    end
  end

  def validate(_recipe), do: {:error, "recipe must be a JSON object"}

  defp validate_keys(recipe) do
    case Map.keys(recipe) -- @known_keys do
      [] -> :ok
      extra -> {:error, "unknown recipe keys: #{Enum.join(extra, ", ")}"}
    end
  end

  defp validate_where(nil), do: :ok

  defp validate_where(conditions) when is_list(conditions) do
    Enum.find_value(conditions, :ok, fn condition ->
      case validate_condition(condition) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp validate_where(_), do: {:error, "where must be a list of conditions"}

  defp validate_condition(%{"field" => field, "op" => op} = condition) when is_binary(field) do
    cond do
      Map.keys(condition) -- ~w(field op value) != [] ->
        {:error, "a condition only has field, op and value"}

      not Regex.match?(@field_re, field) ->
        {:error, "field #{field} is not allowed"}

      op not in @filter_ops ->
        {:error, "unknown filter op #{inspect(op)}"}

      op == "exists" and Map.has_key?(condition, "value") ->
        {:error, "exists takes no value"}

      op != "exists" and not Map.has_key?(condition, "value") ->
        {:error, "op #{op} needs a value"}

      op in @numeric_ops and not (is_number(condition["value"]) or is_binary(condition["value"])) ->
        {:error, "op #{op} needs a number or an ISO date string"}

      op == "contains" and not is_binary(condition["value"]) ->
        {:error, "contains needs a string value"}

      true ->
        :ok
    end
  end

  defp validate_condition(_), do: {:error, "each condition needs field and op"}

  defp validate_group_by(nil), do: :ok

  defp validate_group_by(group) when is_binary(group) do
    if group in @time_buckets or Regex.match?(@field_re, group) do
      :ok
    else
      {:error, "group_by must be a field path or day/week/month"}
    end
  end

  defp validate_group_by(_), do: {:error, "group_by must be a string"}

  defp validate_aggregate(nil), do: :ok

  defp validate_aggregate(%{"op" => op} = aggregate) do
    cond do
      Map.keys(aggregate) -- ~w(op field) != [] ->
        {:error, "aggregate only has op and field"}

      op not in @aggregate_ops ->
        {:error, "unknown aggregate op #{inspect(op)}"}

      op == "count" and Map.has_key?(aggregate, "field") ->
        {:error, "count takes no field"}

      op != "count" and not (is_binary(aggregate["field"]) and Regex.match?(@field_re, aggregate["field"])) ->
        {:error, "aggregate #{op} needs an allowed field path"}

      true ->
        :ok
    end
  end

  defp validate_aggregate(_), do: {:error, "aggregate must be an object with an op"}

  defp validate_emit_if(nil, _recipe), do: :ok

  defp validate_emit_if(%{"op" => op, "value" => value} = emit, recipe) do
    cond do
      Map.keys(emit) -- ~w(op value) != [] ->
        {:error, "emit_if only has op and value"}

      op not in @emit_ops ->
        {:error, "emit_if op must be a comparison (#{Enum.join(@emit_ops, ", ")})"}

      not is_number(value) ->
        {:error, "emit_if value must be a number"}

      Map.get(recipe, "aggregate") == nil ->
        {:error, "emit_if needs an aggregate"}

      Map.get(recipe, "group_by") != nil ->
        {:error, "emit_if cannot be combined with group_by"}

      true ->
        :ok
    end
  end

  defp validate_emit_if(_, _recipe), do: {:error, "emit_if must be an object with op and value"}

  # ----- interpretation -----

  @doc """
  Interprets a validated recipe over the window's entries (assumed sorted
  by occurred_at desc). Returns {:ok, markdown} or :skip when emit_if is
  false.
  """
  def run(recipe, entries) do
    filtered = apply_where(entries, Map.get(recipe, "where"))

    case Map.get(recipe, "aggregate") do
      nil ->
        {:ok, digest(filtered)}

      aggregate ->
        case Map.get(recipe, "group_by") do
          nil -> single(recipe, aggregate, filtered)
          group -> {:ok, table(group, aggregate, filtered)}
        end
    end
  end

  defp apply_where(entries, nil), do: entries

  defp apply_where(entries, conditions) do
    Enum.filter(entries, fn entry ->
      Enum.all?(conditions, fn condition ->
        matches?(get_path(entry, condition["field"]), condition["op"], condition["value"])
      end)
    end)
  end

  defp matches?(value, "exists", _), do: not is_nil(value)
  defp matches?(nil, _op, _value), do: false
  defp matches?(%DateTime{} = value, op, expected), do: matches?(DateTime.to_iso8601(value), op, expected)
  defp matches?(value, "eq", expected), do: value == expected
  defp matches?(value, "neq", expected), do: value != expected

  defp matches?(value, "contains", expected) when is_binary(value) and is_binary(expected),
    do: String.contains?(value, expected)

  defp matches?(value, op, expected)
       when op in @numeric_ops and
              ((is_number(value) and is_number(expected)) or
                 (is_binary(value) and is_binary(expected))) do
    case op do
      "gt" -> value > expected
      "gte" -> value >= expected
      "lt" -> value < expected
      "lte" -> value <= expected
    end
  end

  defp matches?(_value, _op, _expected), do: false

  defp get_path(entry, "title"), do: entry.title
  defp get_path(entry, "source"), do: entry.source
  defp get_path(entry, "occurred_at"), do: entry.occurred_at
  defp get_path(entry, "data." <> rest), do: dig(entry.data, String.split(rest, "."))
  defp get_path(entry, "metadata." <> rest), do: dig(entry.metadata, String.split(rest, "."))
  defp get_path(_entry, _field), do: nil

  defp dig(value, []), do: value
  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  # ----- aggregates -----

  defp single(recipe, aggregate, entries) do
    value = aggregate_value(aggregate, entries)

    if emit?(Map.get(recipe, "emit_if"), value) do
      label = aggregate_label(aggregate)
      {:ok, "#{label}: #{fmt(value)}\n\n(#{length(entries)} entries considered)"}
    else
      :skip
    end
  end

  defp emit?(nil, _value), do: true
  defp emit?(_emit, nil), do: false

  defp emit?(%{"op" => op, "value" => expected}, value) do
    case op do
      "eq" -> value == expected
      "neq" -> value != expected
      "gt" -> value > expected
      "gte" -> value >= expected
      "lt" -> value < expected
      "lte" -> value <= expected
    end
  end

  defp aggregate_value(%{"op" => "count"}, entries), do: length(entries)

  defp aggregate_value(%{"op" => "last", "field" => field}, entries) do
    Enum.find_value(entries, fn entry -> get_path(entry, field) end)
  end

  defp aggregate_value(%{"op" => op, "field" => field}, entries) do
    numbers = for entry <- entries, value = get_path(entry, field), is_number(value), do: value

    case {op, numbers} do
      {"sum", numbers} -> Enum.sum(numbers)
      {_op, []} -> nil
      {"avg", numbers} -> Enum.sum(numbers) / length(numbers)
      {"min", numbers} -> Enum.min(numbers)
      {"max", numbers} -> Enum.max(numbers)
    end
  end

  defp aggregate_label(%{"op" => "count"}), do: "count"
  defp aggregate_label(%{"op" => op, "field" => field}), do: "#{op}(#{field})"

  defp fmt(nil), do: "no data"
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(Float.round(value, 2), decimals: 2)
  defp fmt(value), do: to_string(value)

  # ----- grouped table -----

  defp table(group, aggregate, entries) do
    time_bucket? = group in @time_buckets

    rows =
      entries
      |> Enum.group_by(&group_key(&1, group, time_bucket?))
      |> Enum.reject(fn {key, _} -> time_bucket? and key == nil end)
      |> Enum.map(fn {key, grouped} -> {key || "-", aggregate_value(aggregate, grouped)} end)
      |> sort_rows(time_bucket?)

    if rows == [] do
      "(no entries)"
    else
      header = "| #{group} | #{aggregate_label(aggregate)} |\n| --- | --- |"
      body = Enum.map_join(rows, "\n", fn {key, value} -> "| #{key} | #{fmt(value)} |" end)
      header <> "\n" <> body
    end
  end

  defp group_key(entry, group, false) do
    case get_path(entry, group) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp group_key(entry, bucket, true) do
    case entry.occurred_at do
      nil -> nil
      occurred_at -> bucket_label(DateTime.to_date(occurred_at), bucket)
    end
  end

  defp bucket_label(date, "day"), do: Date.to_iso8601(date)
  defp bucket_label(date, "month"), do: String.slice(Date.to_iso8601(date), 0, 7)

  defp bucket_label(date, "week") do
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp sort_rows(rows, true), do: Enum.sort_by(rows, fn {key, _} -> key end)

  defp sort_rows(rows, false) do
    if Enum.all?(rows, fn {_, value} -> is_number(value) end) do
      Enum.sort_by(rows, fn {_, value} -> value end, :desc)
    else
      Enum.sort_by(rows, fn {key, _} -> key end)
    end
  end

  # ----- digest -----

  defp digest([]), do: "(no entries)"

  defp digest(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      date = (entry.occurred_at && Date.to_iso8601(DateTime.to_date(entry.occurred_at))) || "-"
      "- #{date} | #{entry.title || "-"}"
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/servant/agents/recipe_test.exs`
Expected: PASS. If a formatting or ordering assertion is off, fix the test only if the implementation is genuinely correct per spec (table sorted by value desc for field groups, chronological for buckets).

- [ ] **Step 5: Run the full backend suite**

Run: `mix test`
Expected: PASS (no existing test touches this new module).

---

### Task 2: Agent schema gains mode + recipe

**Files:**
- Create: migration via `mix ecto.gen.migration add_mode_and_recipe_to_agents`
- Modify: `lib/servant/agents/agent.ex`
- Test: `test/servant/agents_test.exs` (add a describe block)

**Interfaces:**
- Consumes: `Servant.Agents.Recipe.validate/1` (Task 1).
- Produces: `Agent` schema with `mode` (binary, default "prompt") and `recipe` (map or nil); changeset accepts and validates both. Task 3 branches on `agent.mode` and reads `agent.recipe`; Task 5 casts them from the API.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration add_mode_and_recipe_to_agents`

Edit the generated file to:

```elixir
defmodule Servant.Repo.Migrations.AddModeAndRecipeToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :mode, :string, null: false, default: "prompt"
      add :recipe, :map
    end
  end
end
```

Run: `mix ecto.migrate`
Expected: migrated without error (SQLite supports additive ADD COLUMN with default).

- [ ] **Step 2: Write the failing tests**

Add to `test/servant/agents_test.exs` (inside the existing module, new describe block; reuse the file's existing user fixture helper, check its name at the top of the file):

```elixir
  describe "recipe agents CRUD" do
    test "mode defaults to prompt and prompt stays required" do
      user = user_fixture()

      assert {:error, changeset} = Agents.create_agent(user.id, %{"name" => "A", "kinds" => ["note"]})
      assert %{prompt: _} = errors_on(changeset)

      assert {:ok, agent} =
               Agents.create_agent(user.id, %{"name" => "A", "prompt" => "p", "kinds" => ["note"]})

      assert agent.mode == "prompt"
      assert agent.recipe == nil
    end

    test "mode recipe requires a valid recipe and no prompt" do
      user = user_fixture()

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{"name" => "A", "kinds" => ["note"], "mode" => "recipe"})

      assert %{recipe: _} = errors_on(changeset)

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "recipe",
                 "recipe" => %{"bogus" => true}
               })

      assert %{recipe: _} = errors_on(changeset)

      assert {:ok, agent} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "recipe",
                 "recipe" => %{"aggregate" => %{"op" => "count"}}
               })

      assert agent.mode == "recipe"
      assert agent.prompt == nil
    end

    test "unknown mode is rejected" do
      user = user_fixture()

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "prompt" => "p",
                 "kinds" => ["note"],
                 "mode" => "script"
               })

      assert %{mode: _} = errors_on(changeset)
    end
  end
```

Run: `mix test test/servant/agents_test.exs`
Expected: FAIL (mode not cast, recipe unknown).

- [ ] **Step 3: Update the schema and changeset**

In `lib/servant/agents/agent.ex`:

1. Update the `@moduledoc` to:

```elixir
  @moduledoc """
  A recurring agent run on a schedule over a selection of the user's
  entries. Two modes: "prompt" (the model writes an ai_report entry) and
  "recipe" (a declarative recipe interpreted deterministically, producing
  a report entry with no model call).
  """
```

2. Add after `@schedules`:

```elixir
  @modes ~w(prompt recipe)
```

3. Add the fields to the schema block, after `field :prompt`:

```elixir
    field :mode, :string, default: "prompt"
    field :recipe, :map
```

4. Replace the changeset with:

```elixir
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :prompt, :mode, :recipe, :kinds, :lookback_days, :schedule, :enabled])
    |> validate_required([:name, :kinds])
    |> validate_inclusion(:mode, @modes)
    |> validate_length(:name, max: 60)
    |> validate_length(:prompt, max: 4000)
    |> update_change(:kinds, &Enum.uniq/1)
    |> validate_kinds()
    |> validate_number(:lookback_days, greater_than: 0, less_than_or_equal_to: 365)
    |> validate_inclusion(:schedule, @schedules)
    |> validate_by_mode()
  end

  # Prompt agents need a prompt; recipe agents need a valid recipe.
  defp validate_by_mode(changeset) do
    case get_field(changeset, :mode) do
      "recipe" ->
        changeset
        |> validate_required([:recipe])
        |> validate_change(:recipe, fn :recipe, recipe ->
          case Servant.Agents.Recipe.validate(recipe) do
            :ok -> []
            {:error, message} -> [recipe: message]
          end
        end)

      _mode ->
        validate_required(changeset, [:prompt])
    end
  end
```

(`alias Servant.Agents.Recipe` at the top of the module, in alphabetical position, and use `Recipe.validate(recipe)` in the body.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/servant/agents_test.exs`
Expected: PASS, including all pre-existing tests (prompt agents unchanged).

---

### Task 3: Recipe execution branch

**Files:**
- Modify: `lib/servant/data.ex` (add `entries_window/3`)
- Modify: `lib/servant/agents.ex` (branch on mode, `execute_recipe`, `store_recipe_report`)
- Test: `test/servant/agents_test.exs`

**Interfaces:**
- Consumes: `Recipe.run/2` (Task 1), `agent.mode` / `agent.recipe` (Task 2).
- Produces: `Servant.Data.entries_window(user_id, kinds, from_dt) :: [Entry.t]` (occurred_at desc, unpaginated). `Agents.run_now/3` and `Agents.start_run/2` transparently handle recipe agents; skip returns `{:ok, nil, run}`. The report entry has `kind: "report"` and metadata `%{"agent_id" => ..., "run_id" => ...}` (no "model" key).

- [ ] **Step 1: Write the failing tests**

Add to `test/servant/agents_test.exs`. Mirror the file's existing setup for prompt-agent run tests (user fixture with ai_config enabled, `Req.Test` stub opts); reuse its helpers. New describe block:

```elixir
  describe "recipe agent runs" do
    # No ai_opts / no stub anywhere in this block: a recipe run must never
    # touch the model server.

    defp recipe_agent(user, recipe, attrs \\ %{}) do
      {:ok, agent} =
        Agents.create_agent(
          user.id,
          Map.merge(
            %{"name" => "R", "kinds" => ["bank_tx"], "mode" => "recipe", "recipe" => recipe},
            attrs
          )
        )

      agent
    end

    test "produces a kind report entry without model metadata, run has no tokens" do
      user = ai_user_fixture()

      {:ok, _} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "t",
          "occurred_at" => DateTime.utc_now(),
          "data" => %{"amount" => 12}
        })

      agent = recipe_agent(user, %{"aggregate" => %{"op" => "sum", "field" => "data.amount"}})

      assert {:ok, entry, run} = Agents.run_now(user, agent)

      assert entry.kind == "report"
      assert entry.source == "agent"
      assert entry.data["content"] =~ "12"
      assert entry.metadata["agent_id"] == agent.id
      assert entry.metadata["run_id"] == run.id
      refute Map.has_key?(entry.metadata, "model")

      assert run.status == "ok"
      assert run.model == nil
      assert run.input_tokens == nil
      assert run.duration_ms != nil
    end

    test "emit_if false completes the run without creating an entry" do
      user = ai_user_fixture()

      agent =
        recipe_agent(user, %{
          "aggregate" => %{"op" => "count"},
          "emit_if" => %{"op" => "gte", "value" => 1}
        })

      assert {:ok, nil, run} = Agents.run_now(user, agent)
      assert run.status == "ok"
      assert Servant.Data.all_entries(user.id, %{"kind" => "report"}) == []
    end

    test "the window is not capped by pagination (60 entries all counted)" do
      user = ai_user_fixture()

      for i <- 1..60 do
        {:ok, _} =
          Servant.Data.create_entry(user.id, %{
            "kind" => "bank_tx",
            "source" => "test",
            "title" => "t#{i}",
            "occurred_at" => DateTime.utc_now(),
            "data" => %{"amount" => 1}
          })
      end

      agent = recipe_agent(user, %{"aggregate" => %{"op" => "count"}})

      assert {:ok, entry, _run} = Agents.run_now(user, agent)
      assert entry.data["content"] =~ "60"
    end

    test "only entries inside the lookback window count" do
      user = ai_user_fixture()

      {:ok, old} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "old",
          "occurred_at" => DateTime.add(DateTime.utc_now(), -10 * 86_400, :second),
          "data" => %{}
        })

      _ = old

      agent =
        recipe_agent(user, %{"aggregate" => %{"op" => "count"}}, %{"lookback_days" => 7})

      assert {:ok, entry, _run} = Agents.run_now(user, agent)
      assert entry.data["content"] =~ "0"
    end
  end
```

Note: `ai_user_fixture()` stands for whatever helper the file already uses to build a user with agents enabled (`update_ai_config` with enabled + model). Use the existing one; only add this alias-style helper if none exists.

Run: `mix test test/servant/agents_test.exs`
Expected: FAIL (recipe agents go down the prompt path and crash on `String.slice(nil, ...)` or the AI call).

- [ ] **Step 2: Add `Data.entries_window/3`**

In `lib/servant/data.ex`, next to `all_entries/2` (respect the module's existing alias/imports; `Entry` and `Repo` are already in scope):

```elixir
  @doc """
  All entries of the given kinds with occurred_at >= from, newest first,
  unpaginated. Used by agent recipes: a truncated aggregate would be a
  wrong number, and there is no token cost pushing for a cap.
  """
  def entries_window(user_id, kinds, from_dt) do
    Entry
    |> where(user_id: ^user_id)
    |> where([e], e.kind in ^kinds)
    |> where([e], e.occurred_at >= ^from_dt)
    |> order_by(desc: :occurred_at)
    |> Repo.all()
  end
```

- [ ] **Step 3: Branch the run pipeline in `lib/servant/agents.ex`**

1. Add `alias Servant.Agents.Recipe` (alphabetical, after `Servant.Agents.Agent`).

2. Update the `@moduledoc` first paragraph to mention the two recurrent modes (prompt reports and deterministic recipes).

3. In `prepare_run/2`, replace the `create_run` attrs so recipe runs carry no model and a nil prompt is tolerated:

```elixir
        result =
          create_run(user.id, %{
            type: "recurrent",
            action: "report",
            agent_id: agent.id,
            status: "running",
            model: if(agent.mode == "recipe", do: nil, else: config["model"]),
            prompt: agent.prompt && String.slice(agent.prompt, 0, 2000)
          })
```

4. In `run_now/3`, dispatch on mode:

```elixir
  def run_now(user, agent, ai_opts \\ []) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      case agent.mode do
        "recipe" -> execute_recipe(run, user, agent)
        _mode -> execute_report(run, user, agent, ai_opts)
      end
    end
  end
```

5. In `start_run/2`, same dispatch inside the supervised Task:

```elixir
  def start_run(user, agent) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Servant.Agents.TaskSupervisor, fn ->
          case agent.mode do
            "recipe" -> execute_recipe(run, user, agent)
            _mode -> execute_report(run, user, agent, [])
          end
        end)

      {:ok, run}
    end
  end
```

6. Add the recipe path (below `execute_report`; same try/rescue discipline):

```elixir
  defp execute_recipe(run, user, agent) do
    started = System.monotonic_time(:millisecond)

    try do
      from_dt = DateTime.add(DateTime.utc_now(), -agent.lookback_days * 86_400, :second)
      entries = Data.entries_window(user.id, agent.kinds, from_dt)

      case Recipe.run(agent.recipe, entries) do
        {:ok, content} ->
          store_recipe_report(run, user, agent, content, started)

        :skip ->
          {:ok, run} = complete_run(run, nil, elapsed(started))
          {:ok, nil, run}
      end
    rescue
      exception ->
        {:ok, _run} = fail_run(run, Exception.message(exception), nil, elapsed(started))
        reraise exception, __STACKTRACE__
    end
  end

  defp store_recipe_report(run, user, agent, content, started) do
    attrs = %{
      "kind" => "report",
      "source" => "agent",
      "title" => "#{agent.name} - #{Date.to_iso8601(Date.utc_today())}",
      "occurred_at" => DateTime.utc_now(),
      "data" => %{"content" => content},
      "metadata" => %{"agent_id" => agent.id, "run_id" => run.id}
    }

    case Data.create_entry(user.id, attrs) do
      {:ok, entry} ->
        {:ok, run} = complete_run(run, nil, elapsed(started))
        {:ok, entry, run}

      {:error, %Ecto.Changeset{}} ->
        {:ok, run} = fail_run(run, "could not store the report", nil, elapsed(started))
        {:error, run.error, run}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/servant/agents_test.exs`
Expected: PASS, including every pre-existing prompt-agent test.

- [ ] **Step 5: Full suite**

Run: `mix test`
Expected: PASS.

---

### Task 4: LLM draft of a recipe

**Files:**
- Modify: `lib/servant/agents.ex` (`draft_recipe/4`, system prompt, parse + repair)
- Test: `test/servant/agents_test.exs`

**Interfaces:**
- Consumes: `Servant.AI.chat/3` (existing), `Recipe.validate/1` (Task 1), `Data.all_entries/2`.
- Produces: `Agents.draft_recipe(user, description, kinds, ai_opts \\ []) :: {:ok, recipe_map, run} | {:error, message, run} | {:error, message}` (the last shape for pre-run failures: agents disabled, blank description). Task 5 exposes it over HTTP.

- [ ] **Step 1: Write the failing tests**

Add to `test/servant/agents_test.exs` (reuse the file's Req.Test stub pattern used by the prompt-run tests; the stub goes through `ai_opts` as `plug: ...`):

```elixir
  describe "draft_recipe/4" do
    defp ai_json(recipe) do
      %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(recipe)}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }
    end

    test "returns the validated recipe and a tracked run" do
      user = ai_user_fixture()
      recipe = %{"aggregate" => %{"op" => "count"}}

      plug = fn conn -> Req.Test.json(conn, ai_json(recipe)) end

      assert {:ok, ^recipe, run} =
               Agents.draft_recipe(user, "count my transactions", ["bank_tx"], plug: plug)

      assert run.action == "draft_recipe"
      assert run.type == "recurrent"
      assert run.status == "ok"
      assert run.input_tokens == 10
      assert run.agent_id == nil
    end

    test "the draft prompt carries kinds and data keys, never values" do
      user = ai_user_fixture()

      {:ok, _} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "secret shop",
          "occurred_at" => DateTime.utc_now(),
          "data" => %{"amount" => 4242, "category" => "hidden-category"}
        })

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:ai_request, body})
        Req.Test.json(conn, ai_json(%{"aggregate" => %{"op" => "count"}}))
      end

      assert {:ok, _recipe, _run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)

      assert_receive {:ai_request, body}
      assert body =~ "bank_tx"
      assert body =~ "data.amount"
      assert body =~ "data.category"
      refute body =~ "4242"
      refute body =~ "hidden-category"
      refute body =~ "secret shop"
    end

    test "invalid first reply gets one repair round with cumulative usage" do
      user = ai_user_fixture()
      counter = start_supervised!({Agent, fn -> 0 end})

      plug = fn conn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "not json at all"}}],
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
          })
        else
          Req.Test.json(conn, ai_json(%{"aggregate" => %{"op" => "count"}}))
        end
      end

      assert {:ok, _recipe, run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)
      assert run.status == "ok"
      assert run.input_tokens == 20
      assert run.output_tokens == 10
    end

    test "two invalid replies fail the run" do
      user = ai_user_fixture()

      plug = fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "{\"bogus\": true}"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end

      assert {:error, message, run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)
      assert message =~ "unknown"
      assert run.status == "error"
    end

    test "refuses when agents are disabled or the description is blank" do
      user = user_fixture()
      assert {:error, _} = Agents.draft_recipe(user, "count", ["bank_tx"])

      ai_user = ai_user_fixture()
      assert {:error, _} = Agents.draft_recipe(ai_user, "  ", ["bank_tx"])
    end
  end
```

(`Agent` here is Elixir's stdlib `Agent` used as a counter; it does not clash because the test file refers to our schema as `Agents.create_agent` results, never by the bare `Agent` alias. If the test file does alias `Servant.Agents.Agent`, use `:counters.new(1, [])` instead: `counter = :counters.new(1, [])`, `n = :counters.get(counter, 1)`, `:counters.add(counter, 1, 1)`.)

Run: `mix test test/servant/agents_test.exs`
Expected: FAIL (`draft_recipe/4` undefined).

- [ ] **Step 2: Implement `draft_recipe` in `lib/servant/agents.ex`**

1. Add the module attribute next to `@report_system_prompt`:

```elixir
  @recipe_system_prompt """
  You translate a plain-language description of a recurring data script
  into a JSON recipe. Reply with a single JSON object only: no code
  fence, no prose.

  Recipe shape (every key optional):
  - "where": array of {"field", "op", "value"} conditions, AND semantics.
    Ops: eq, neq, contains, gt, gte, lt, lte, exists (exists takes no
    value). Fields: "title", "source", "occurred_at", "data.<key>",
    "metadata.<key>".
  - "group_by": a field path, or "day" | "week" | "month" (buckets on the
    entry date).
  - "aggregate": {"op": one of sum avg count min max last, "field": a
    field path}. count takes no field. Omit aggregate to list the entries
    instead.
  - "emit_if": {"op": one of eq neq gt gte lt lte, "value": a number}.
    Only valid with an aggregate and without group_by: the report is only
    produced when the aggregated value matches.
  """
```

2. Add the public function and helpers (place after `run_due/1`, before the private section):

```elixir
  @doc """
  Asks the configured model to translate a plain-language description
  into a recipe (authoring time only; execution never calls the model).
  The prompt carries entry kinds and data key names, never values. One
  repair round on an invalid reply. Every draft is a tracked run.
  """
  def draft_recipe(user, description, kinds, ai_opts \\ []) do
    config = Accounts.ai_config(user)

    cond do
      config["enabled"] != true ->
        {:error, "agents are disabled in Settings"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "description is required"}

      true ->
        do_draft(user, config, description, List.wrap(kinds), ai_opts)
    end
  end

  defp do_draft(user, config, description, kinds, ai_opts) do
    {:ok, run} =
      create_run(user.id, %{
        type: "recurrent",
        action: "draft_recipe",
        status: "running",
        model: config["model"],
        prompt: String.slice(description, 0, 2000)
      })

    started = System.monotonic_time(:millisecond)

    try do
      messages = [
        %{role: "system", content: @recipe_system_prompt},
        %{role: "user", content: draft_request(user.id, description, kinds)}
      ]

      case AI.chat(config, messages, ai_opts) do
        {:ok, %{content: content, usage: usage}} ->
          case parse_recipe(content) do
            {:ok, recipe} ->
              {:ok, run} = complete_run(run, usage, elapsed(started))
              {:ok, recipe, run}

            {:error, message} ->
              repair_draft(run, config, messages, content, message, usage, started, ai_opts)
          end

        {:error, message} ->
          {:ok, run} = fail_run(run, message, nil, elapsed(started))
          {:error, message, run}
      end
    rescue
      exception ->
        {:ok, _run} = fail_run(run, Exception.message(exception), nil, elapsed(started))
        reraise exception, __STACKTRACE__
    end
  end

  defp repair_draft(run, config, messages, previous, message, usage, started, ai_opts) do
    messages =
      messages ++
        [
          %{role: "assistant", content: previous},
          %{
            role: "user",
            content:
              "That recipe is invalid: #{message}. Reply with a corrected JSON object only."
          }
        ]

    case AI.chat(config, messages, ai_opts) do
      {:ok, %{content: content, usage: usage2}} ->
        total = add_usage(usage, usage2)

        case parse_recipe(content) do
          {:ok, recipe} ->
            {:ok, run} = complete_run(run, total, elapsed(started))
            {:ok, recipe, run}

          {:error, message2} ->
            {:ok, run} = fail_run(run, message2, total, elapsed(started))
            {:error, message2, run}
        end

      {:error, message2} ->
        {:ok, run} = fail_run(run, message2, usage, elapsed(started))
        {:error, message2, run}
    end
  end

  defp parse_recipe(content) do
    json =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, content) do
        [_, fenced] -> fenced
        nil -> String.trim(content)
      end

    case Jason.decode(json) do
      {:ok, recipe} when is_map(recipe) ->
        case Recipe.validate(recipe) do
          :ok -> {:ok, recipe}
          {:error, _} = error -> error
        end

      {:ok, _other} ->
        {:error, "the reply must be a JSON object"}

      {:error, _} ->
        {:error, "the reply is not valid JSON"}
    end
  end

  defp draft_request(user_id, description, kinds) do
    keys = sample_keys(user_id, kinds)
    keys_line = if keys == [], do: "(none found)", else: Enum.join(keys, ", ")

    "Script: #{description}\n\n" <>
      "Entry kinds: #{Enum.join(kinds, ", ")}\n" <>
      "Known data fields (from recent entries, names only): #{keys_line}"
  end

  # Key names only: the draft never needs personal values.
  defp sample_keys(user_id, kinds) do
    user_id
    |> Data.all_entries(%{"kinds" => kinds, "per_page" => 20})
    |> Enum.flat_map(fn entry ->
      entry.data |> Map.keys() |> Enum.map(&"data.#{&1}")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_usage(nil, usage), do: usage
  defp add_usage(usage, nil), do: usage

  defp add_usage(a, b) do
    %{input_tokens: a.input_tokens + b.input_tokens, output_tokens: a.output_tokens + b.output_tokens}
  end
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `mix test test/servant/agents_test.exs`
Expected: PASS.

- [ ] **Step 4: Full suite**

Run: `mix test`
Expected: PASS.

---

### Task 5: API surface (draft endpoint + mode/recipe on CRUD)

**Files:**
- Modify: `lib/servant_web/controllers/agent_controller.ex`
- Modify: `lib/servant_web/router.ex`
- Test: `test/servant_web/controllers/agent_controller_test.exs`

**Interfaces:**
- Consumes: `Agents.draft_recipe/4` (Task 4), changeset mode/recipe (Task 2).
- Produces: `POST /api/agents/draft_recipe` returning `{"data": {"recipe": ..., "run_id": ...}}`; `agent_json` includes `mode` and `recipe`. Task 6 calls both.

- [ ] **Step 1: Write the failing tests**

Add to `test/servant_web/controllers/agent_controller_test.exs` (reuse the file's existing session/auth setup and its agents-enabled fixture; the stub pattern for AI-backed endpoints exists in `app_controller_test.exs` if needed: the controller passes no ai_opts, so stub via `Req.Test` global config is NOT available; instead these controller tests stub nothing and only exercise validation paths, plus one success path using the `Req.Test.stub` + `plug` convention already used in this file for run tests if present; if the file has no such convention, only test the failure paths and the CRUD, the success path is covered by Task 4's context tests):

```elixir
  describe "POST /api/agents/draft_recipe" do
    test "422 with a blank description", %{conn: conn} do
      conn = post(conn, ~p"/api/agents/draft_recipe", %{"description" => " ", "kinds" => ["x"]})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "recipe agents over the API" do
    test "creates and returns a recipe agent", %{conn: conn} do
      params = %{
        "name" => "Weekly spend",
        "mode" => "recipe",
        "kinds" => ["bank_tx"],
        "recipe" => %{"aggregate" => %{"op" => "count"}}
      }

      conn = post(conn, ~p"/api/agents", params)
      body = json_response(conn, 201)

      assert body["data"]["mode"] == "recipe"
      assert body["data"]["recipe"] == %{"aggregate" => %{"op" => "count"}}
    end

    test "invalid recipe is a 422", %{conn: conn} do
      params = %{
        "name" => "Bad",
        "mode" => "recipe",
        "kinds" => ["bank_tx"],
        "recipe" => %{"nope" => 1}
      }

      conn = post(conn, ~p"/api/agents", params)
      assert %{"errors" => %{"recipe" => _}} = json_response(conn, 422)
    end
  end
```

Adapt the two test names above to the file's existing conn setup (it already logs in and enables agents for most describes; put these tests in the same setup context).

Run: `mix test test/servant_web/controllers/agent_controller_test.exs`
Expected: FAIL (route missing, mode/recipe absent from agent_json).

- [ ] **Step 2: Add the route**

In `lib/servant_web/router.ex`, next to the existing agent runs routes (they are declared BEFORE `resources "/agents"` so literal segments are not captured as `:id`; keep that ordering), add:

```elixir
    post "/agents/draft_recipe", AgentController, :draft_recipe
```

- [ ] **Step 3: Extend the controller**

In `lib/servant_web/controllers/agent_controller.ex`:

1. Extend `@agent` schema properties with:

```elixir
      mode: %Schema{type: :string, enum: ["prompt", "recipe"]},
      recipe: %Schema{type: :object, nullable: true},
```

2. Extend the `:create` request body properties with:

```elixir
           mode: %Schema{type: :string, enum: ["prompt", "recipe"]},
           recipe: %Schema{type: :object},
```

and change its `required:` list to `[:name, :kinds]` (prompt is only required in prompt mode; the changeset enforces the cross-field rule).

3. Add the operation + action (before the private helpers):

```elixir
  operation(:draft_recipe,
    summary: "Draft a recipe from a plain-language description",
    description:
      "Session-only; requires agents enabled in Settings. Asks the configured model to " <>
        "translate the description into a recipe (tracked as a draft_recipe run). The " <>
        "prompt carries entry kinds and data key names, never entry values.",
    request_body:
      {"Draft request", "application/json",
       %Schema{
         type: :object,
         properties: %{
           description: %Schema{type: :string},
           kinds: %Schema{type: :array, items: %Schema{type: :string}}
         },
         required: [:description]
       }},
    responses: [
      ok: {"Recipe", "application/json", %Schema{type: :object}},
      unprocessable_entity: {"Invalid description or model reply", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def draft_recipe(conn, params) do
    kinds = params["kinds"] |> List.wrap() |> Enum.filter(&is_binary/1)

    case Agents.draft_recipe(conn.assigns.current_user, params["description"], kinds) do
      {:ok, recipe, run} ->
        json(conn, %{data: %{recipe: recipe, run_id: run.id}})

      {:error, message, _run} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end
```

4. Extend `agent_json/1` with:

```elixir
      mode: agent.mode,
      recipe: agent.recipe,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/servant_web/controllers/agent_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `mix test`
Expected: PASS (OpenAPI spec test, if any, picks up the new operation automatically).

---

### Task 6: Frontend (mode selector, draft flow, merged reports)

**Files:**
- Modify: `frontend/src/types.ts`
- Modify: `frontend/src/views/AgentsView.vue`

**Interfaces:**
- Consumes: `POST /api/agents/draft_recipe` -> `{data: {recipe, run_id}}`; agents CRUD with `mode` + `recipe`; entries kinds `ai_report` and `report` (Task 5, Task 3).
- Produces: user-visible feature; no downstream consumer.

- [ ] **Step 1: Types**

In `frontend/src/types.ts`, extend `Agent`:

```ts
export interface Agent {
  id: string
  name: string
  prompt: string | null
  mode: 'prompt' | 'recipe'
  recipe: Record<string, unknown> | null
  kinds: string[]
  lookback_days: number
  schedule: 'every_hour' | 'every_day' | 'every_week'
  enabled: boolean
  last_run_at: string | null
  inserted_at: string
}
```

(`prompt` becomes nullable; check `openEdit` below compensates with `|| ''`.)

- [ ] **Step 2: Script changes in `frontend/src/views/AgentsView.vue`**

1. Add form state next to the existing `fSchedule` ref:

```ts
const fMode = ref<'prompt' | 'recipe'>('prompt')
const fDescription = ref('')
const fRecipeJson = ref('')
const drafting = ref(false)

const MODE_OPTIONS = [
  { value: 'prompt', label: 'Prompt (the model writes the report)' },
  { value: 'recipe', label: 'Recipe (deterministic, no model at run time)' }
]
```

2. Replace `loadReports` with a merged fetch (model reports + deterministic reports):

```ts
async function loadReports() {
  const [ai, det] = await Promise.all([
    api.get<{ data: Entry[] }>('/api/entries', {
      kind: 'ai_report',
      per_page: '200'
    }),
    api.get<{ data: Entry[] }>('/api/entries', {
      kind: 'report',
      per_page: '200'
    })
  ])
  reports.value = [...ai.data, ...det.data].sort((a, b) =>
    (b.occurred_at || b.inserted_at).localeCompare(
      a.occurred_at || a.inserted_at
    )
  )
}
```

3. Reset the new refs in `openCreate` (add lines):

```ts
  fMode.value = 'prompt'
  fDescription.value = ''
  fRecipeJson.value = ''
```

4. Fill them in `openEdit` (add lines; also adjust `fPrompt` for nullability):

```ts
  fPrompt.value = a.prompt || ''
  fMode.value = a.mode
  fDescription.value = ''
  fRecipeJson.value = a.recipe ? JSON.stringify(a.recipe, null, 2) : ''
```

5. Rework the body construction in `saveAgent`:

```ts
  const body: Record<string, unknown> = {
    name: fName.value.trim(),
    mode: fMode.value,
    kinds: fKinds.value
      .split(',')
      .map(k => k.trim())
      .filter(Boolean),
    lookback_days: fLookback.value,
    schedule: fSchedule.value
  }
  if (fMode.value === 'recipe') {
    try {
      body.recipe = JSON.parse(fRecipeJson.value)
    } catch {
      agentError.value = 'Recipe is not valid JSON'
      fSaving.value = false
      return
    }
  } else {
    body.prompt = fPrompt.value.trim()
  }
```

(keep the surrounding try/catch/finally of `saveAgent` unchanged; move the `fSaving.value = true` line above the body construction so the early return can reset it, as shown.)

6. Add the draft action:

```ts
async function draftRecipe() {
  agentError.value = ''
  drafting.value = true
  try {
    const res = await api.post<{
      data: { recipe: Record<string, unknown>; run_id: string }
    }>('/api/agents/draft_recipe', {
      description: fDescription.value.trim(),
      kinds: fKinds.value
        .split(',')
        .map(k => k.trim())
        .filter(Boolean)
    })
    fRecipeJson.value = JSON.stringify(res.data.recipe, null, 2)
    await loadRecurrentRuns()
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Draft failed'
  } finally {
    drafting.value = false
  }
}
```

- [ ] **Step 3: Template changes**

1. In the agents list table, show the mode in the Name cell:

```html
                  <td>
                    {{ a.name }}
                    <span class="mode-badge">{{ a.mode }}</span>
                  </td>
```

2. In the form, insert the mode selector right after the name input, and make the prompt textarea conditional. Replace the current prompt textarea block with:

```html
              <label class="tk-expiry">
                <span class="tk-domain-label">Mode</span>
                <ComboBox
                  class="tk-domain-select"
                  :model-value="fMode"
                  :options="MODE_OPTIONS"
                  @update:model-value="v => (fMode = v as 'prompt' | 'recipe')"
                />
              </label>
              <textarea
                v-if="fMode === 'prompt'"
                v-model="fPrompt"
                rows="3"
                placeholder="What should the agent look for or summarize?"
              ></textarea>
              <template v-if="fMode === 'recipe'">
                <textarea
                  v-model="fDescription"
                  rows="2"
                  placeholder="Describe the script, e.g. sum bank_tx amounts by category each week"
                ></textarea>
                <div class="card-actions">
                  <button
                    type="button"
                    :disabled="drafting || !fDescription.trim() || !fKinds.trim()"
                    @click="draftRecipe"
                  >
                    {{ drafting ? 'Drafting...' : 'Generate recipe' }}
                  </button>
                </div>
                <textarea
                  v-model="fRecipeJson"
                  rows="8"
                  class="recipe-json"
                  placeholder='{"aggregate": {"op": "count"}}'
                ></textarea>
                <p class="tk-hint">
                  The recipe runs deterministically on schedule; the model is
                  only used here, to draft it. Edit it freely before saving.
                </p>
              </template>
```

(the kinds input stays where it is, before Lookback; the draft button needs kinds filled to know the fields, hence its disabled rule.)

3. Update the submit button's `:disabled` expression to account for the mode:

```html
                  :disabled="
                    fSaving ||
                    !fName.trim() ||
                    !fKinds.trim() ||
                    (fMode === 'prompt' ? !fPrompt.trim() : !fRecipeJson.trim())
                  "
```

4. In the recurring runs table, the model cell becomes:

```html
                  <td>{{ r.model || '-' }}</td>
```

(and the same in the builder runs table for consistency if it renders bare `r.model`.)

- [ ] **Step 4: Styles**

Add to the scoped style block:

```css
.mode-badge {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  font-size: 0.7rem;
  margin-left: 0.35rem;
  padding: 0.05rem 0.4rem;
}
.recipe-json {
  font-family: monospace;
  font-size: 0.85rem;
}
```

- [ ] **Step 5: Format, build, test**

Run: `cd frontend && npm run format && npm run build && npx vitest run`
Expected: build exit 0, all vitest tests pass. Fix any TypeScript error surfaced by the nullable `prompt` (only `openEdit` and the template use it; both are covered above).

---

### Task 7: Prompt-context pagination fix

The prompt path documents a 200-entry cap but `Data.all_entries` paginates at 50 by default, so prompt agents silently see at most 50 entries. Ask for one page of 201: the split at 200 then correctly flags truncation.

**Files:**
- Modify: `lib/servant/agents.ex` (`build_context/2`)
- Test: `test/servant/agents_test.exs`

**Interfaces:** none new; internal fix.

- [ ] **Step 1: Write the failing test**

Add to `test/servant/agents_test.exs`, in the prompt-agent runs describe (reuse its stub helpers):

```elixir
    test "the prompt context is not silently capped at the default page size" do
      user = ai_user_fixture()

      for i <- 1..60 do
        {:ok, _} =
          Servant.Data.create_entry(user.id, %{
            "kind" => "bank_tx",
            "source" => "test",
            "title" => "line#{i}",
            "occurred_at" => DateTime.utc_now(),
            "data" => %{}
          })
      end

      {:ok, agent} =
        Agents.create_agent(user.id, %{
          "name" => "P",
          "prompt" => "summarize",
          "kinds" => ["bank_tx"]
        })

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:ai_request, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "report"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end

      assert {:ok, _entry, _run} = Agents.run_now(user, agent, plug: plug)

      assert_receive {:ai_request, body}
      assert body =~ "line60"
      assert body =~ "line1"
    end
```

Run: `mix test test/servant/agents_test.exs`
Expected: FAIL (only 50 entries reach the request body).

- [ ] **Step 2: Fix `build_context/2`**

In `lib/servant/agents.ex`, the `all_entries` call becomes:

```elixir
    entries =
      Data.all_entries(user_id, %{
        "kinds" => agent.kinds,
        "from" => from_iso,
        "per_page" => @max_context_entries + 1
      })
```

(+1 so `Enum.split(entries, @max_context_entries)` still detects that more entries existed and sets the truncated marker.)

- [ ] **Step 3: Run tests to verify they pass**

Run: `mix test test/servant/agents_test.exs`
Expected: PASS, including the pre-existing truncation-marker test.

---

### Task 8: Docs + final verification

**Files:**
- Modify: `DEVELOPMENT.md` (Agents bullet in Architecture notes)

**Interfaces:** none.

- [ ] **Step 1: Extend the Agents bullet**

In `DEVELOPMENT.md`, replace the sentence describing recurring agents inside the **Agents** bullet so the bullet reads (keep the surrounding text of the bullet intact):

```markdown
- **Agents** share one per-user AI config (`users.ai_config`, encrypted) and one `agent_runs` history (model, tokens, duration per run). Two types ship today: the **builder** (`Servant.Apps.Generator`, turns a description into an installed custom app) and **recurring agents** (`agents` table + `Servant.Agents.Scheduler`) in two modes: a prompt run on a schedule over selected entries producing `ai_report` entries, or a deterministic **recipe** (`Servant.Agents.Recipe`, drafted once by the model, zero tokens at run time) producing `report` entries. Both call one OpenAI-compatible endpoint (`Servant.AI`). Disabled by default (Settings > Agents); the UI lives in the Agents section.
```

- [ ] **Step 2: Final verification**

Run: `mix precommit`
Expected: exit 0, all backend tests green.

Run: `cd frontend && npm run build && npx vitest run`
Expected: build exit 0, all tests green.

Run: `rtk proxy grep -rn "—" lib/ frontend/src/ DEVELOPMENT.md`
Expected: no hits outside the known legacy-separator parsing fallbacks.
