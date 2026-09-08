# Agent Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store coding-agent memory and skills as `agent_memory` entries, exposed through `/api/agent_memory` (manifest, batch upsert by path, delete), a Notes-like read/edit app, and a skill (with pull/push scripts) that lets Claude Code and Cursor sync themselves between machines.

**Architecture:** One entry per file (`kind: "agent_memory"`, `source: "agent"`, `external_id` = path so the existing unique index enforces path uniqueness). A `Servant.AgentMemory` context derives `project`/`tool`/`title` from the path and upserts by path; a thin controller exposes it under the `agent_memory` scope domain. The Vue app builds a tree from paths client side and renders markdown with the Notes renderer. The skill is markdown plus two bash scripts shipped in `docs/skills/servant-memory/`.

**Tech Stack:** Elixir/Phoenix (Ecto, OpenApiSpex), Vue 3 + TypeScript (vitest), bash + curl + jq for the skill scripts.

**Spec:** `docs/superpowers/specs/2026-09-08-agent-memory-design.md`

## Global Constraints

- Never write em dashes (—) anywhere: code, comments, docs, commit messages. Use a comma, colon, parentheses or a plain hyphen.
- Elixir: `@moduledoc` right after `defmodule`, directives ordered `use`, `import`, `alias` (alphabetical); no single-pipe expressions; predicate functions end in `?`; in tests `assert actual == expected`.
- Vue: multi-word component names, typed `defineProps<{...}>()`, `:key` on every `v-for`, `scoped` styles, SFC order `<script>` then `<template>` then `<style>`; design tokens (`var(--primary)`, `var(--font-mono)`), never literal colors or font stacks; no single-letter variable names (except loop index `i` and sort comparator `(a, b)`); derive in computeds, not in the template.
- Import order in `<script setup>`: framework, then components, then app modules sorted by path, then `import type` last.
- Use Servant widgets (`ctx.confirm.ask` for confirmations) before native controls.
- Search field gets focus on mount (`autofocus`).
- Run `mix format` after Elixir edits, `cd frontend && npm run format` after frontend edits, `mix precommit` at the end.
- Commit messages: `<area>: <lowercase summary>`, ending with the two attribution lines:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01YJdFjHJ1h3W2bxgPbhVtBd
  ```

---

## File structure

| File | Responsibility |
|------|----------------|
| `lib/servant/api_tokens/scopes.ex` (modify) | add the `agent_memory` domain and the `agent_memory` kind mapping |
| `frontend/src/lib/apiTokenScopes.ts` (modify) | label for the new domain in Settings > API tokens |
| `lib/servant/agent_memory.ex` (create) | context: path parsing, list with filters, batch upsert by path, delete by path, JSON shape |
| `test/servant/agent_memory_test.exs` (create) | context tests |
| `lib/servant_web/controllers/agent_memory_controller.ex` (create) | `index` / `upsert` / `delete` actions with OpenAPI operations |
| `lib/servant_web/router.ex` (modify) | three routes under `/api/agent_memory` |
| `test/servant_web/controllers/agent_memory_controller_test.exs` (create) | controller and scope tests |
| `frontend/src/apps/agent_memory/tree.ts` (create) | `buildTree(files)`: paths to nested nodes |
| `frontend/src/apps/agent_memory/tree.test.ts` (create) | tree builder test |
| `frontend/src/apps/agent_memory/AgentMemoryApp.vue` (create) | the app: tree, markdown view, edit, delete |
| `frontend/src/apps/agent_memory/index.ts` (create) | `defineVueApp` adapter |
| `frontend/src/apps/registry.ts` (modify) | register the app (first, alphabetical by name) |
| `frontend/src/components/AppSidebar.vue` (modify) | map the `Brain` icon |
| `docs/skills/servant-memory/SKILL.md` (create) | the skill agents read |
| `docs/skills/servant-memory/scripts/pull.sh` (create) | pull memory + skills for the current repo |
| `docs/skills/servant-memory/scripts/push.sh` (create) | push local files by path |
| `CLAUDE.md` (modify) | one "See also" line pointing at the skill |

---

### Task 1: Scope domain `agent_memory`

**Files:**
- Modify: `lib/servant/api_tokens/scopes.ex:10-26`
- Modify: `frontend/src/lib/apiTokenScopes.ts:7-17`
- Test: `test/servant/api_tokens_test.exs` (append a test)

**Interfaces:**
- Produces: scope strings `app:agent_memory:read` / `app:agent_memory:write`; `Scopes.kind_domain("agent_memory") == "agent_memory"`. Task 3's `plug ServantWeb.Plugs.Scope, domain: "agent_memory"` relies on it.

- [ ] **Step 1: Write the failing test**

Append to the last `describe` block's parent module in `test/servant/api_tokens_test.exs` (anywhere inside the module, at the top level of the module body):

```elixir
  describe "agent_memory scope" do
    test "is a valid domain mapped to the agent_memory kind" do
      assert Servant.ApiTokens.Scopes.valid?("app:agent_memory:write")
      assert Servant.ApiTokens.Scopes.kind_domain("agent_memory") == "agent_memory"
      assert Servant.ApiTokens.Scopes.can_kind?(["app:agent_memory:read"], "agent_memory", :read)
      refute Servant.ApiTokens.Scopes.can_kind?(["app:notes:write"], "agent_memory", :read)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/servant/api_tokens_test.exs`
Expected: FAIL on `valid?("app:agent_memory:write")` (returns false).

- [ ] **Step 3: Add the domain and the kind mapping**

In `lib/servant/api_tokens/scopes.ex`:

```elixir
  @app_domains ~w(notes checklists calendar contacts photos files finance trackers agent_memory)

  @kind_to_domain %{
    "note" => "notes",
    "checklist" => "checklists",
    "event" => "calendar",
    "contact" => "contacts",
    "photo" => "photos",
    "file" => "files",
    "account" => "finance",
    "balance" => "finance",
    "bank_tx" => "finance",
    "blockchain_tx" => "finance",
    "invoice" => "finance",
    "tracker" => "trackers",
    "tracker_log" => "trackers",
    "agent_memory" => "agent_memory"
  }
```

In `frontend/src/lib/apiTokenScopes.ts`, add before the `data` row:

```ts
  { id: 'agent_memory', label: 'Agent memory' },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/servant/api_tokens_test.exs test/servant_web/controllers/entry_scopes_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/servant/api_tokens/scopes.ex frontend/src/lib/apiTokenScopes.ts test/servant/api_tokens_test.exs
git commit -m "api tokens: agent_memory scope domain"
```

---

### Task 2: `Servant.AgentMemory` context

**Files:**
- Create: `lib/servant/agent_memory.ex`
- Test: `test/servant/agent_memory_test.exs`

**Interfaces:**
- Consumes: `Servant.Data.Entry` (schema + `changeset/2`), `Servant.Events.broadcast/2`, `Servant.Repo`.
- Produces (used by Task 3):
  - `parse_path(String.t()) :: {:ok, %{"path", "project", "tool", "title"}} | {:error, :invalid_path}`
  - `list(user_id, %{optional("project") => String.t(), optional("tool") => String.t()}) :: [Entry.t()]`
  - `upsert_all(user_id, [%{"path" => String.t(), "body" => String.t()}]) :: {:ok, [Entry.t()]} | {:error, :invalid_path}`
  - `delete(user_id, path) :: {:ok, Entry.t()} | {:error, :not_found}`
  - `to_json(Entry.t(), include_body? :: boolean) :: map`

- [ ] **Step 1: Write the failing tests**

`test/servant/agent_memory_test.exs`:

```elixir
defmodule Servant.AgentMemoryTest do
  use Servant.DataCase

  alias Servant.AgentMemory

  setup do
    %{user: user_fixture(), other: user_fixture()}
  end

  describe "parse_path/1" do
    test "memory files belong to a project and to claude" do
      assert AgentMemory.parse_path("memory/servant-elixir/MEMORY.md") ==
               {:ok,
                %{
                  "path" => "memory/servant-elixir/MEMORY.md",
                  "project" => "servant-elixir",
                  "tool" => "claude",
                  "title" => "MEMORY.md"
                }}
    end

    test "skills are global and belong to their tool" do
      assert {:ok, %{"project" => "", "tool" => "cursor", "title" => "SKILL.md"}} =
               AgentMemory.parse_path("skills/cursor/create-rule/SKILL.md")

      assert {:ok, %{"tool" => "shared", "title" => "codex-tools.md"}} =
               AgentMemory.parse_path("skills/shared/brainstorming/references/codex-tools.md")
    end

    test "rules belong to a project and to cursor" do
      assert {:ok, %{"project" => "kitsu", "tool" => "cursor", "title" => "style.mdc"}} =
               AgentMemory.parse_path("rules/kitsu/style.mdc")
    end

    test "rejects bad prefixes, traversal, bad segments and missing segments" do
      for path <- [
            "notes/x/y.md",
            "memory/../etc/passwd",
            "memory/a b/c.md",
            "memory/servant-elixir",
            "skills/claude/only-name",
            "skills/vim/x/SKILL.md",
            "",
            nil
          ] do
        assert AgentMemory.parse_path(path) == {:error, :invalid_path}, path
      end
    end
  end

  describe "upsert_all/2" do
    test "creates entries keyed by path with a server-side sha256", %{user: user} do
      {:ok, [entry]} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "hello"}])

      assert entry.kind == "agent_memory"
      assert entry.source == "agent"
      assert entry.external_id == "memory/proj/a.md"
      assert entry.title == "a.md"
      assert entry.data["project"] == "proj"
      assert entry.data["tool"] == "claude"
      assert entry.data["body"] == "hello"

      assert entry.data["sha256"] ==
               :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    end

    test "replaces the body of an existing path and skips unchanged ones", %{user: user} do
      {:ok, [first]} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "v1"}])

      {:ok, [same]} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "v1"}])

      assert same.id == first.id
      assert same.updated_at == first.updated_at

      {:ok, [changed]} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "v2"}])

      assert changed.id == first.id
      assert changed.data["body"] == "v2"
      assert length(AgentMemory.list(user.id)) == 1
    end

    test "rejects the whole batch on one invalid path", %{user: user} do
      assert AgentMemory.upsert_all(user.id, [
               %{"path" => "memory/proj/a.md", "body" => "ok"},
               %{"path" => "bad/a.md", "body" => "no"}
             ]) == {:error, :invalid_path}

      assert AgentMemory.list(user.id) == []
    end

    test "rejects a non-string body", %{user: user} do
      assert AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => 1}]) ==
               {:error, :invalid_path}
    end
  end

  describe "list/2" do
    setup %{user: user, other: other} do
      {:ok, _} =
        AgentMemory.upsert_all(user.id, [
          %{"path" => "memory/proj/MEMORY.md", "body" => "m"},
          %{"path" => "memory/other-proj/MEMORY.md", "body" => "m"},
          %{"path" => "skills/claude/kitsu/SKILL.md", "body" => "s"},
          %{"path" => "skills/shared/brainstorm/SKILL.md", "body" => "s"},
          %{"path" => "skills/cursor/rule/SKILL.md", "body" => "s"},
          %{"path" => "rules/proj/style.mdc", "body" => "r"}
        ])

      {:ok, _} =
        AgentMemory.upsert_all(other.id, [%{"path" => "memory/proj/MEMORY.md", "body" => "x"}])

      :ok
    end

    test "returns the caller's files sorted by path", %{user: user} do
      paths = user.id |> AgentMemory.list() |> Enum.map(& &1.data["path"])

      assert paths == [
               "memory/other-proj/MEMORY.md",
               "memory/proj/MEMORY.md",
               "rules/proj/style.mdc",
               "skills/claude/kitsu/SKILL.md",
               "skills/cursor/rule/SKILL.md",
               "skills/shared/brainstorm/SKILL.md"
             ]
    end

    test "project filter keeps global files, tool filter keeps shared ones", %{user: user} do
      paths =
        user.id
        |> AgentMemory.list(%{"project" => "proj", "tool" => "claude"})
        |> Enum.map(& &1.data["path"])

      assert paths == [
               "memory/proj/MEMORY.md",
               "skills/claude/kitsu/SKILL.md",
               "skills/shared/brainstorm/SKILL.md"
             ]
    end
  end

  describe "delete/2" do
    test "removes by path and reports missing ones", %{user: user, other: other} do
      {:ok, _} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "x"}])

      assert {:error, :not_found} = AgentMemory.delete(other.id, "memory/proj/a.md")
      assert {:ok, _} = AgentMemory.delete(user.id, "memory/proj/a.md")
      assert {:error, :not_found} = AgentMemory.delete(user.id, "memory/proj/a.md")
    end
  end

  describe "to_json/2" do
    test "manifest shape, body on demand", %{user: user} do
      {:ok, [entry]} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "héllo"}])

      json = AgentMemory.to_json(entry)
      assert json.path == "memory/proj/a.md"
      assert json.size == 6
      refute Map.has_key?(json, :body)
      assert AgentMemory.to_json(entry, true).body == "héllo"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/servant/agent_memory_test.exs`
Expected: FAIL, `Servant.AgentMemory` is undefined.

- [ ] **Step 3: Write the context**

`lib/servant/agent_memory.ex`:

```elixir
defmodule Servant.AgentMemory do
  @moduledoc """
  Memory and skills of coding agents (Claude Code, Cursor), one `agent_memory`
  entry per file, identified by its path (`external_id`, so the entries unique
  index makes paths unique per user). Agents push and pull through
  `/api/agent_memory`; the app reads, edits and deletes through the same routes.

  Everything derives from the path:

    * `memory/<project>/<file>`: project memory, tool `claude`
    * `skills/<tool>/<name>/<file>` (and deeper): global skill, project `""`
    * `rules/<project>/<file>`: Cursor rules, tool `cursor`
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Events
  alias Servant.Repo

  @kind "agent_memory"
  @source "agent"
  @tools ~w(claude cursor shared)
  @segment ~r/^[A-Za-z0-9._-]+$/

  @doc "Derives project, tool and title from a path."
  @spec parse_path(term) :: {:ok, map} | {:error, :invalid_path}
  def parse_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    with true <- Enum.all?(segments, &valid_segment?/1),
         {:ok, project, tool} <- classify(segments) do
      {:ok,
       %{"path" => path, "project" => project, "tool" => tool, "title" => List.last(segments)}}
    else
      _ -> {:error, :invalid_path}
    end
  end

  def parse_path(_), do: {:error, :invalid_path}

  defp classify(["memory", project, _file | _]), do: {:ok, project, "claude"}
  defp classify(["skills", tool, _name, _file | _]) when tool in @tools, do: {:ok, "", tool}
  defp classify(["rules", project, _file | _]), do: {:ok, project, "cursor"}
  defp classify(_), do: :error

  defp valid_segment?(segment) do
    segment not in [".", ".."] and Regex.match?(@segment, segment)
  end

  @doc """
  Lists a user's files sorted by path. `project` also keeps global files
  (project `""`), `tool` also keeps `shared` ones, so one call returns what a
  session in a repo needs.
  """
  @spec list(String.t(), map) :: [Entry.t()]
  def list(user_id, filters \\ %{}) do
    from(e in Entry,
      where: e.user_id == ^user_id and e.kind == @kind,
      order_by: [asc: e.external_id]
    )
    |> filter_project(filters["project"])
    |> filter_tool(filters["tool"])
    |> Repo.all()
  end

  defp filter_project(query, nil), do: query

  defp filter_project(query, project) do
    where(query, [e], fragment("json_extract(?, '$.project')", e.data) in ^[project, ""])
  end

  defp filter_tool(query, nil), do: query

  defp filter_tool(query, tool) do
    where(query, [e], fragment("json_extract(?, '$.tool')", e.data) in ^[tool, "shared"])
  end

  @doc """
  Upserts `[%{"path", "body"}]` by path in one transaction. Any invalid file
  rejects the whole batch. An unchanged body is left alone (`updated_at` stays).
  """
  @spec upsert_all(String.t(), list) :: {:ok, [Entry.t()]} | {:error, :invalid_path}
  def upsert_all(user_id, files) when is_list(files) do
    with {:ok, parsed} <- parse_all(files) do
      Repo.transaction(fn ->
        Enum.map(parsed, fn {attrs, body} -> upsert_one(user_id, attrs, body) end)
      end)
    end
  end

  defp parse_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"path" => path, "body" => body}, {:ok, acc} when is_binary(body) ->
        case parse_path(path) do
          {:ok, attrs} -> {:cont, {:ok, [{attrs, body} | acc]}}
          error -> {:halt, error}
        end

      _file, _acc ->
        {:halt, {:error, :invalid_path}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp upsert_one(user_id, attrs, body) do
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    data = attrs |> Map.delete("title") |> Map.merge(%{"body" => body, "sha256" => sha})

    case get_by_path(user_id, attrs["path"]) do
      nil ->
        {:ok, entry} =
          %Entry{user_id: user_id, kind: @kind, source: @source}
          |> Entry.changeset(%{
            title: attrs["title"],
            external_id: attrs["path"],
            occurred_at: DateTime.truncate(DateTime.utc_now(), :second),
            data: data
          })
          |> Repo.insert()

        Events.broadcast(user_id, {:entry_created, entry})
        entry

      %Entry{data: %{"sha256" => ^sha}} = entry ->
        entry

      entry ->
        {:ok, entry} =
          entry
          |> Entry.changeset(%{title: attrs["title"], data: data})
          |> Repo.update()

        Events.broadcast(user_id, {:entry_updated, entry})
        entry
    end
  end

  defp get_by_path(user_id, path) do
    Repo.get_by(Entry, user_id: user_id, kind: @kind, source: @source, external_id: path)
  end

  @doc "Deletes the file at `path`."
  @spec delete(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def delete(user_id, path) do
    case get_by_path(user_id, path) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, entry} = Repo.delete(entry)
        Events.broadcast(user_id, {:entry_deleted, entry})
        {:ok, entry}
    end
  end

  @doc "Manifest row for a file; `include_body?` adds the markdown."
  @spec to_json(Entry.t(), boolean) :: map
  def to_json(%Entry{} = entry, include_body? \\ false) do
    body = entry.data["body"] || ""

    base = %{
      id: entry.id,
      path: entry.data["path"],
      project: entry.data["project"],
      tool: entry.data["tool"],
      sha256: entry.data["sha256"],
      size: byte_size(body),
      updated_at: entry.updated_at
    }

    if include_body?, do: Map.put(base, :body, body), else: base
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/servant/agent_memory_test.exs`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/servant/agent_memory.ex test/servant/agent_memory_test.exs
git commit -m "agent memory: context with path-keyed upserts"
```

---

### Task 3: `/api/agent_memory` controller and routes

**Files:**
- Create: `lib/servant_web/controllers/agent_memory_controller.ex`
- Modify: `lib/servant_web/router.ex:66-68` (right after the notes routes)
- Test: `test/servant_web/controllers/agent_memory_controller_test.exs`

**Interfaces:**
- Consumes: `Servant.AgentMemory.list/2`, `upsert_all/2`, `delete/2`, `to_json/2` (Task 2); scope domain `agent_memory` (Task 1).
- Produces: `GET /api/agent_memory?project=&tool=&include=body`, `POST /api/agent_memory {files: [{path, body}]}`, `DELETE /api/agent_memory?path=`. The frontend (Task 5) and the skill scripts (Task 6) call these.

- [ ] **Step 1: Write the failing tests**

`test/servant_web/controllers/agent_memory_controller_test.exs`:

```elixir
defmodule ServantWeb.AgentMemoryControllerTest do
  use ServantWeb.ConnCase

  alias Servant.AgentMemory

  describe "scopes" do
    test "403 without app:agent_memory scopes" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:notes:write"])

      assert json_response(get(conn, ~p"/api/agent_memory"), 403)["required"] ==
               "app:agent_memory:read"

      conn2 = post(conn, ~p"/api/agent_memory", %{"files" => []})
      assert json_response(conn2, 403)["required"] == "app:agent_memory:write"
    end

    test "read scope lists but cannot write" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:agent_memory:read"])
      assert json_response(get(conn, ~p"/api/agent_memory"), 200)["data"] == []
      assert json_response(post(conn, ~p"/api/agent_memory", %{"files" => []}), 403)
    end
  end

  describe "with app:agent_memory:write" do
    setup do
      {conn, user} = register_and_log_in_api_token(build_conn(), ["app:agent_memory:write"])
      %{conn: conn, user: user}
    end

    test "batch upsert returns the manifest without bodies", %{conn: conn} do
      conn =
        post(conn, ~p"/api/agent_memory", %{
          "files" => [
            %{"path" => "memory/proj/MEMORY.md", "body" => "# index"},
            %{"path" => "skills/claude/kitsu/SKILL.md", "body" => "skill"}
          ]
        })

      assert %{"data" => [memory, skill]} = json_response(conn, 200)
      assert memory["path"] == "memory/proj/MEMORY.md"
      assert memory["project"] == "proj"
      assert memory["size"] == 7
      assert is_binary(memory["sha256"])
      assert is_binary(memory["updated_at"])
      refute Map.has_key?(memory, "body")
      assert skill["tool"] == "claude"
    end

    test "422 on an invalid path, nothing written", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/agent_memory", %{
          "files" => [
            %{"path" => "memory/proj/ok.md", "body" => "ok"},
            %{"path" => "../etc/passwd", "body" => "no"}
          ]
        })

      assert json_response(conn, 422)["error"] =~ "path"
      assert AgentMemory.list(user.id) == []
    end

    test "422 when files is missing", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/agent_memory", %{}), 422)
    end

    test "index filters and includes bodies on demand", %{conn: conn, user: user} do
      {:ok, _} =
        AgentMemory.upsert_all(user.id, [
          %{"path" => "memory/proj/MEMORY.md", "body" => "m"},
          %{"path" => "memory/other/MEMORY.md", "body" => "m"},
          %{"path" => "skills/shared/brainstorm/SKILL.md", "body" => "s"},
          %{"path" => "rules/proj/style.mdc", "body" => "r"}
        ])

      paths =
        get(conn, ~p"/api/agent_memory?project=proj&tool=claude")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["path"])

      assert paths == ["memory/proj/MEMORY.md", "skills/shared/brainstorm/SKILL.md"]

      [first | _] = json_response(get(conn, ~p"/api/agent_memory?include=body"), 200)["data"]
      assert first["body"] == "m"
    end

    test "delete by path: 204 then 404", %{conn: conn, user: user} do
      {:ok, _} =
        AgentMemory.upsert_all(user.id, [%{"path" => "memory/proj/a.md", "body" => "x"}])

      assert response(delete(conn, ~p"/api/agent_memory?path=memory/proj/a.md"), 204)
      assert json_response(delete(conn, ~p"/api/agent_memory?path=memory/proj/a.md"), 404)
    end

    test "does not see another user's files", %{conn: conn} do
      other = user_fixture()
      {:ok, _} = AgentMemory.upsert_all(other.id, [%{"path" => "memory/p/a.md", "body" => "x"}])
      assert json_response(get(conn, ~p"/api/agent_memory"), 200)["data"] == []
      assert json_response(delete(conn, ~p"/api/agent_memory?path=memory/p/a.md"), 404)
    end
  end

  test "session tokens have full access" do
    {conn, _user} = register_and_log_in_user(build_conn())

    conn =
      post(conn, ~p"/api/agent_memory", %{
        "files" => [%{"path" => "memory/proj/a.md", "body" => "x"}]
      })

    assert [%{"path" => "memory/proj/a.md"}] = json_response(conn, 200)["data"]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/servant_web/controllers/agent_memory_controller_test.exs`
Expected: FAIL, routes do not exist (404 or `Phoenix.Router.NoRouteError`).

- [ ] **Step 3: Write the controller**

`lib/servant_web/controllers/agent_memory_controller.ex`:

```elixir
defmodule ServantWeb.AgentMemoryController do
  @moduledoc """
  Agent memory files (memory, skills, rules of coding agents): manifest,
  batch upsert by path, delete by path. The pull/push scripts of the
  `servant-memory` skill and the Agent memory app are the callers.
  """

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.AgentMemory
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.Scope, domain: "agent_memory"

  tags(["agent_memory"])

  @file_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      path: %Schema{type: :string, description: "memory/<project>/…, skills/<tool>/…, rules/<project>/…"},
      project: %Schema{type: :string, description: "Repo folder name, empty for global files"},
      tool: %Schema{type: :string, enum: ["claude", "cursor", "shared"]},
      sha256: %Schema{type: :string},
      size: %Schema{type: :integer, description: "Body size in bytes"},
      updated_at: %Schema{type: :string, format: :"date-time"},
      body: %Schema{type: :string, description: "Only with include=body"}
    }
  }
  @file_list %Schema{
    type: :object,
    properties: %{data: %Schema{type: :array, items: @file_schema}}
  }

  operation(:index,
    summary: "List agent memory files",
    description:
      "Manifest sorted by path. `project` also returns global files, `tool` also returns shared ones. Requires app:agent_memory:read for an API token.",
    parameters: [
      project: [in: :query, type: :string, description: "Repo folder name"],
      tool: [in: :query, type: :string, description: "claude or cursor"],
      include: [in: :query, type: :string, description: "`body` to include file bodies"]
    ],
    responses: [
      ok: {"Files", "application/json", @file_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    include_body? = params["include"] == "body"
    files = AgentMemory.list(user_id, Map.take(params, ["project", "tool"]))
    json(conn, %{data: Enum.map(files, &AgentMemory.to_json(&1, include_body?))})
  end

  operation(:upsert,
    summary: "Upsert agent memory files by path",
    description:
      "Creates or replaces each file; unchanged bodies are left alone. One invalid path rejects the whole batch. Requires app:agent_memory:write for an API token.",
    request_body:
      {"Files", "application/json",
       %Schema{
         type: :object,
         required: [:files],
         properties: %{
           files: %Schema{
             type: :array,
             items: %Schema{
               type: :object,
               required: [:path, :body],
               properties: %{path: %Schema{type: :string}, body: %Schema{type: :string}}
             }
           }
         }
       }},
    responses: [
      ok: {"Manifest of the files sent", "application/json", @file_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid path", "application/json", Schemas.Error}
    ]
  )

  def upsert(conn, %{"files" => files}) when is_list(files) do
    user_id = conn.assigns.current_user.id

    case AgentMemory.upsert_all(user_id, files) do
      {:ok, entries} ->
        json(conn, %{data: Enum.map(entries, &AgentMemory.to_json/1)})

      {:error, :invalid_path} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid file path or body"})
    end
  end

  operation(:delete,
    summary: "Delete an agent memory file",
    description: "Requires app:agent_memory:write for an API token.",
    parameters: [path: [in: :query, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"path" => path}) do
    user_id = conn.assigns.current_user.id

    case AgentMemory.delete(user_id, path) do
      {:ok, _entry} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
```

In `lib/servant_web/router.ex`, right after `resources "/notes", NotesController, except: [:new, :edit]`:

```elixir
      get "/agent_memory", AgentMemoryController, :index
      post "/agent_memory", AgentMemoryController, :upsert
      delete "/agent_memory", AgentMemoryController, :delete
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/servant_web/controllers/agent_memory_controller_test.exs`
Expected: PASS (9 tests). If the OpenAPI validator rejects the missing-`files` case with a different status, keep the `422` assertion and check `ServantWeb.Plugs.OpenApiError` renders 422 (it does for the notes controller).

- [ ] **Step 5: Check the OpenAPI spec still builds**

Run: `mix test test/servant_web/controllers/docs_controller_test.exs 2>/dev/null || mix test test/servant_web`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/servant_web/controllers/agent_memory_controller.ex lib/servant_web/router.ex test/servant_web/controllers/agent_memory_controller_test.exs
git commit -m "web: /api/agent_memory manifest, batch upsert and delete"
```

---

### Task 4: Frontend tree builder

**Files:**
- Create: `frontend/src/apps/agent_memory/tree.ts`
- Test: `frontend/src/apps/agent_memory/tree.test.ts`

**Interfaces:**
- Produces (used by Task 5):
  ```ts
  export interface MemoryFile { id: string; path: string; project: string; tool: string; sha256: string; size: number; updated_at: string; body?: string }
  export interface TreeNode { name: string; path: string; children: TreeNode[]; file?: MemoryFile }
  export function buildTree(files: MemoryFile[]): TreeNode[]
  ```
  Root names are `Memory`, `Skills`, `Rules`; folders sort before files, both alphabetical.

- [ ] **Step 1: Write the failing test**

`frontend/src/apps/agent_memory/tree.test.ts`:

```ts
import { describe, expect, it } from 'vitest'

import { buildTree } from './tree'
import type { MemoryFile } from './tree'

function file(path: string): MemoryFile {
  return {
    id: path,
    path,
    project: '',
    tool: 'claude',
    sha256: '',
    size: 0,
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('buildTree', () => {
  it('nests paths under labeled roots, folders first, alphabetical', () => {
    const tree = buildTree([
      file('skills/claude/kitsu/SKILL.md'),
      file('memory/servant-elixir/servant-ui.md'),
      file('memory/servant-elixir/MEMORY.md'),
      file('memory/kitsu/MEMORY.md'),
      file('rules/kitsu/style.mdc')
    ])

    expect(tree.map(node => node.name)).toEqual(['Memory', 'Skills', 'Rules'])

    const memory = tree[0]
    expect(memory.children.map(node => node.name)).toEqual([
      'kitsu',
      'servant-elixir'
    ])

    const servant = memory.children[1]
    expect(servant.path).toBe('memory/servant-elixir')
    expect(servant.children.map(node => node.name)).toEqual([
      'MEMORY.md',
      'servant-ui.md'
    ])
    expect(servant.children[0].file?.path).toBe('memory/servant-elixir/MEMORY.md')

    const skill = tree[1].children[0].children[0]
    expect(skill.name).toBe('kitsu')
    expect(skill.children[0].file?.path).toBe('skills/claude/kitsu/SKILL.md')
  })

  it('omits empty roots', () => {
    expect(buildTree([file('rules/kitsu/style.mdc')]).map(node => node.name)).toEqual([
      'Rules'
    ])
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd frontend && npx vitest run src/apps/agent_memory/tree.test.ts`
Expected: FAIL, cannot resolve `./tree`.

- [ ] **Step 3: Write the tree builder**

`frontend/src/apps/agent_memory/tree.ts`:

```ts
// Turns flat `path`s (memory/<project>/file, skills/<tool>/<name>/file,
// rules/<project>/file) into the nested tree the app renders.

export interface MemoryFile {
  id: string
  path: string
  project: string
  tool: string
  sha256: string
  size: number
  updated_at: string
  body?: string
}

export interface TreeNode {
  name: string
  path: string
  children: TreeNode[]
  file?: MemoryFile
}

const ROOTS: Record<string, string> = {
  memory: 'Memory',
  skills: 'Skills',
  rules: 'Rules'
}

export function buildTree(files: MemoryFile[]): TreeNode[] {
  const roots: TreeNode[] = Object.keys(ROOTS).map(key => ({
    name: ROOTS[key],
    path: key,
    children: []
  }))

  for (const memoryFile of files) {
    const segments = memoryFile.path.split('/')
    let node = roots.find(root => root.path === segments[0])
    if (!node) continue
    for (let i = 1; i < segments.length - 1; i++) {
      const path = segments.slice(0, i + 1).join('/')
      let child = node.children.find(candidate => candidate.path === path)
      if (!child) {
        child = { name: segments[i], path, children: [] }
        node.children.push(child)
      }
      node = child
    }
    node.children.push({
      name: segments[segments.length - 1],
      path: memoryFile.path,
      children: [],
      file: memoryFile
    })
  }

  return roots.filter(root => root.children.length > 0).map(sortNode)
}

function sortNode(node: TreeNode): TreeNode {
  node.children.sort((a, b) => {
    const aFolder = a.file ? 1 : 0
    const bFolder = b.file ? 1 : 0
    return aFolder - bFolder || a.name.localeCompare(b.name)
  })
  node.children.forEach(sortNode)
  return node
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && npx vitest run src/apps/agent_memory/tree.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/apps/agent_memory/tree.ts frontend/src/apps/agent_memory/tree.test.ts
git commit -m "agent memory: tree builder"
```

---

### Task 5: The Agent memory app

**Files:**
- Create: `frontend/src/apps/agent_memory/AgentMemoryApp.vue`
- Create: `frontend/src/apps/agent_memory/index.ts`
- Modify: `frontend/src/apps/registry.ts:4` (insert first entry)
- Modify: `frontend/src/components/AppSidebar.vue:21,37-46` (import `Brain`, add to `appIcons`)

**Interfaces:**
- Consumes: `buildTree`, `MemoryFile`, `TreeNode` (Task 4); `renderMarkdown(body, resolve)` from `../notes/render` (pass `() => null` as `resolve`); `AppContext` (`ctx.api.fetch`, `ctx.confirm.ask`); the three routes of Task 3.
- Produces: app id `agent_memory`, reachable at `/app/agent_memory` once enabled in Settings > Apps.

- [ ] **Step 1: Write the app**

`frontend/src/apps/agent_memory/AgentMemoryApp.vue`:

```vue
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import { renderMarkdown } from '../notes/render'
import { buildTree } from './tree'
import type { AppContext } from '../types'
import type { MemoryFile, TreeNode } from './tree'

const props = defineProps<{ ctx: AppContext }>()

const files = ref<MemoryFile[]>([])
const loading = ref(true)
const loadError = ref('')
const search = ref('')
const selectedPath = ref<string | null>(null)
const editing = ref(false)
const draft = ref('')
const saving = ref(false)

const filteredFiles = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return files.value
  return files.value.filter(memoryFile =>
    memoryFile.path.toLowerCase().includes(needle)
  )
})

const tree = computed(() => buildTree(filteredFiles.value))

const selected = computed(
  () => files.value.find(memoryFile => memoryFile.path === selectedPath.value) ?? null
)

const rendered = computed(() =>
  selected.value ? renderMarkdown(selected.value.body ?? '', () => null) : ''
)

const selectedMeta = computed(() => {
  if (!selected.value) return ''
  const when = new Date(selected.value.updated_at).toLocaleString()
  return `${selected.value.tool} · ${selected.value.size} bytes · ${when}`
})

async function load() {
  loading.value = true
  loadError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory?include=body')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    files.value = json.data
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

function select(node: TreeNode) {
  if (!node.file) return
  selectedPath.value = node.file.path
  editing.value = false
}

function startEdit() {
  if (!selected.value) return
  draft.value = selected.value.body ?? ''
  editing.value = true
}

async function save() {
  if (!selected.value) return
  saving.value = true
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        files: [{ path: selected.value.path, body: draft.value }]
      })
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    const manifest: MemoryFile = json.data[0]
    Object.assign(selected.value, manifest, { body: draft.value })
    editing.value = false
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = false
  }
}

async function remove() {
  if (!selected.value) return
  const ok = await props.ctx.confirm.ask({
    title: 'Delete file',
    message: `Delete ${selected.value.path}? Agents will not pull it any more.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  const path = selected.value.path
  const res = await props.ctx.api.fetch(
    `/api/agent_memory?path=${encodeURIComponent(path)}`,
    { method: 'DELETE' }
  )
  if (!res.ok) {
    loadError.value = `HTTP ${res.status}`
    return
  }
  files.value = files.value.filter(memoryFile => memoryFile.path !== path)
  selectedPath.value = null
}

onMounted(load)
</script>

<template>
  <div class="agent-memory">
    <aside class="tree">
      <input
        v-model="search"
        type="search"
        class="search"
        placeholder="Filter by path"
        aria-label="Filter files by path"
        autofocus
      />
      <p v-if="loading" class="muted">Loading…</p>
      <p v-else-if="loadError" class="error">{{ loadError }}</p>
      <p v-else-if="tree.length === 0" class="muted">
        No files yet. Run the servant-memory skill's push script from a repo.
      </p>
      <ul v-else class="nodes">
        <li v-for="node in tree" :key="node.path">
          <details open>
            <summary>{{ node.name }}</summary>
            <ul class="nodes">
              <template v-for="child in node.children" :key="child.path">
                <li v-if="child.file">
                  <button
                    type="button"
                    class="file"
                    :class="{ 'file--active': child.path === selectedPath }"
                    @click="select(child)"
                  >
                    {{ child.name }}
                  </button>
                </li>
                <li v-else>
                  <details open>
                    <summary>{{ child.name }}</summary>
                    <ul class="nodes">
                      <template v-for="leaf in child.children" :key="leaf.path">
                        <li v-if="leaf.file">
                          <button
                            type="button"
                            class="file"
                            :class="{ 'file--active': leaf.path === selectedPath }"
                            @click="select(leaf)"
                          >
                            {{ leaf.name }}
                          </button>
                        </li>
                        <li v-else>
                          <details open>
                            <summary>{{ leaf.name }}</summary>
                            <ul class="nodes">
                              <li v-for="deep in leaf.children" :key="deep.path">
                                <button
                                  v-if="deep.file"
                                  type="button"
                                  class="file"
                                  :class="{ 'file--active': deep.path === selectedPath }"
                                  @click="select(deep)"
                                >
                                  {{ deep.name }}
                                </button>
                                <span v-else class="muted">{{ deep.name }}/…</span>
                              </li>
                            </ul>
                          </details>
                        </li>
                      </template>
                    </ul>
                  </details>
                </li>
              </template>
            </ul>
          </details>
        </li>
      </ul>
    </aside>

    <section v-if="selected" class="viewer">
      <header class="viewer-head">
        <div>
          <h2 class="path">{{ selected.path }}</h2>
          <p class="muted">{{ selectedMeta }}</p>
        </div>
        <div class="actions">
          <template v-if="editing">
            <button type="button" class="btn" :disabled="saving" @click="editing = false">
              Cancel
            </button>
            <button type="button" class="btn btn--primary" :disabled="saving" @click="save">
              Save
            </button>
          </template>
          <template v-else>
            <button type="button" class="btn" @click="startEdit">Edit</button>
            <button type="button" class="btn btn--danger" @click="remove">Delete</button>
          </template>
        </div>
      </header>
      <textarea
        v-if="editing"
        v-model="draft"
        class="editor"
        aria-label="File body"
        spellcheck="false"
      />
      <!-- eslint-disable-next-line vue/no-v-html: markdown rendered by the shared Notes renderer, which escapes user data -->
      <article v-else class="markdown" v-html="rendered" />
    </section>
    <section v-else class="viewer viewer--empty">
      <p class="muted">Select a file.</p>
    </section>
  </div>
</template>

<style scoped>
.agent-memory {
  display: grid;
  grid-template-columns: minmax(220px, 300px) 1fr;
  gap: 1rem;
  height: 100%;
  min-height: 0;
}

@media (max-width: 800px) {
  .agent-memory {
    grid-template-columns: 1fr;
  }
}

.muted {
  color: var(--text-muted);
  font-size: 0.85rem;
}

.error {
  color: var(--danger);
}

/* ----- Tree ----- */
.tree {
  overflow: auto;
  border-right: 1px solid var(--border);
  padding-right: 0.5rem;
}

.search {
  width: 100%;
  box-sizing: border-box;
  margin-bottom: 0.5rem;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font: inherit;
}

.nodes {
  list-style: none;
  margin: 0;
  padding-left: 0.75rem;
}

.tree > .nodes {
  padding-left: 0;
}

summary {
  cursor: pointer;
  padding: 0.15rem 0;
  font-family: var(--font-mono);
  font-size: 0.85rem;
}

.file {
  display: block;
  width: 100%;
  padding: 0.15rem 0.4rem;
  border: 0;
  border-radius: 4px;
  background: none;
  color: var(--text);
  font-family: var(--font-mono);
  font-size: 0.85rem;
  text-align: left;
  cursor: pointer;
}

.file:hover {
  background: var(--bg-hover);
}

.file--active {
  background: var(--primary);
  color: var(--primary-contrast);
}

/* ----- Viewer ----- */
.viewer {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: auto;
}

.viewer--empty {
  align-items: center;
  justify-content: center;
}

.viewer-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.75rem;
}

.path {
  margin: 0;
  font-family: var(--font-mono);
  font-size: 1rem;
  word-break: break-all;
}

.actions {
  display: flex;
  gap: 0.5rem;
  flex-shrink: 0;
}

.btn {
  padding: 0.35rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font: inherit;
  cursor: pointer;
}

.btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}

.btn--danger {
  color: var(--danger);
}

.editor {
  flex: 1;
  min-height: 60vh;
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-mono);
  font-size: 0.9rem;
  resize: vertical;
}

.markdown {
  line-height: 1.55;
}

.markdown :deep(pre) {
  overflow-x: auto;
  padding: 0.75rem;
  border-radius: 6px;
  background: var(--bg-hover);
}

.markdown :deep(code) {
  font-family: var(--font-mono);
  font-size: 0.9em;
}
</style>
```

Every token used above (`--text`, `--text-muted`, `--border`, `--bg`, `--bg-hover`, `--primary`, `--primary-contrast`, `--danger`, `--font-mono`) is defined in `frontend/src/style.css`; never add a literal color.

`frontend/src/apps/agent_memory/index.ts`:

```ts
import AgentMemoryApp from './AgentMemoryApp.vue'

import { defineVueApp } from '../defineVueApp'

export default defineVueApp(AgentMemoryApp)
```

- [ ] **Step 2: Register the app and its icon**

`frontend/src/apps/registry.ts`, first element of `BUILTIN_APPS` (alphabetical by name, "Agent memory" sorts before "Calendar"):

```ts
  {
    id: 'agent_memory',
    name: 'Agent memory',
    icon: 'Brain',
    builtin: true,
    load: () => import('./agent_memory')
  },
```

Do not add it to `DEFAULT_ENABLED_APPS`.

`frontend/src/components/AppSidebar.vue`: add `Brain` to the `lucide-vue-next` import list (alphabetical: between `Activity` and `Cable`) and to `appIcons`:

```ts
const appIcons: Record<string, unknown> = {
  Brain,
  UserRound,
  CalendarDays,
  FolderOpen,
  Image,
  NotebookPen,
  ListChecks,
  Wallet,
  Target
}
```

- [ ] **Step 3: Type-check, test, format**

Run: `cd frontend && npm run format && npx vue-tsc --noEmit -p tsconfig.app.json 2>/dev/null || npx vue-tsc --noEmit; npm test`
Expected: no type errors; `registry.test.ts` and the rest PASS. If `registry.test.ts` asserts the exact list or order of apps, update the expectation to include `agent_memory` first.

- [ ] **Step 4: Manual check**

Run `mix phx.server` and `cd frontend && npm run dev`, open `http://localhost:5001`, enable "Agent memory" in Settings > Apps, then seed a file from a terminal (session cookie or a `srv_` token with `app:agent_memory:write`):

```bash
curl -sS -H "Authorization: Bearer $SERVANT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"files":[{"path":"memory/demo/MEMORY.md","body":"# Demo\n\n- first line"}]}' \
  http://localhost:4001/api/agent_memory
```

Expected: the file shows under Memory > demo, renders as markdown, Edit/Save round-trips, Delete asks for confirmation and removes it.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/apps/agent_memory frontend/src/apps/registry.ts frontend/src/components/AppSidebar.vue
git commit -m "agent memory: built-in app to read, edit and delete files"
```

---

### Task 6: The `servant-memory` skill and its scripts

**Files:**
- Create: `docs/skills/servant-memory/SKILL.md`
- Create: `docs/skills/servant-memory/scripts/pull.sh`
- Create: `docs/skills/servant-memory/scripts/push.sh`
- Modify: `CLAUDE.md` ("See also" list)

**Interfaces:**
- Consumes: the three routes of Task 3, env `SERVANT_URL` and `SERVANT_TOKEN`.
- Produces: `pull.sh [claude|cursor]` and `push.sh [claude|cursor] <file>...`, both run from the repo root.

- [ ] **Step 1: Write `pull.sh`**

`docs/skills/servant-memory/scripts/pull.sh`:

```bash
#!/usr/bin/env bash
# Pulls the memory and skills of the current repo from Servant.
# Usage: pull.sh [claude|cursor]   (run from the repo root)
# Needs: SERVANT_URL, SERVANT_TOKEN (scope app:agent_memory:write), curl, jq.
set -euo pipefail

tool=${1:-claude}
project=$(basename "$PWD")
: "${SERVANT_URL:?set SERVANT_URL}" "${SERVANT_TOKEN:?set SERVANT_TOKEN}"

# ponytail: Claude mangles the cwd by swapping "/" for "-"; adjust here if it ever changes.
claude_memory="$HOME/.claude/projects/$(pwd | tr / -)/memory"
case "$tool" in
  claude) skills_dir="$HOME/.claude/skills" ;;
  cursor) skills_dir="$HOME/.cursor/skills-cursor" ;;
  *) echo "unknown tool: $tool" >&2; exit 1 ;;
esac

local_path() {
  case "$1" in
    memory/*) echo "$claude_memory/${1#memory/*/}" ;;
    skills/shared/*) echo "$skills_dir/${1#skills/shared/}" ;;
    skills/claude/*) echo "$HOME/.claude/skills/${1#skills/claude/}" ;;
    skills/cursor/*) echo "$HOME/.cursor/skills-cursor/${1#skills/cursor/}" ;;
    rules/*) echo "$PWD/.cursor/rules/${1#rules/*/}" ;;
  esac
}

curl -sSf -H "Authorization: Bearer $SERVANT_TOKEN" \
  "$SERVANT_URL/api/agent_memory?project=$project&tool=$tool&include=body" |
  jq -r '.data[] | [.path, .sha256, .updated_at, (.body | @base64)] | @tsv' |
  while IFS=$'\t' read -r path sha updated body64; do
    dest=$(local_path "$path")
    [ -n "$dest" ] || continue
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -c1-64)" = "$sha" ]; then
      continue
    fi
    if [ -f "$dest" ] && [ "$(date -r "$dest" +%s)" -gt "$(date -d "$updated" +%s)" ]; then
      echo "LOCAL NEWER  $path  (push it, or merge by hand then push)"
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    printf '%s' "$body64" | base64 -d > "$dest"
    echo "pulled       $path"
  done
```

- [ ] **Step 2: Write `push.sh`**

`docs/skills/servant-memory/scripts/push.sh`:

```bash
#!/usr/bin/env bash
# Pushes local memory/skill/rule files to Servant, one POST per file.
# Usage: push.sh [claude|cursor] <file>...   (run from the repo root)
# Needs: SERVANT_URL, SERVANT_TOKEN (scope app:agent_memory:write), curl, jq.
set -euo pipefail

tool=${1:-claude}
shift || true
project=$(basename "$PWD")
: "${SERVANT_URL:?set SERVANT_URL}" "${SERVANT_TOKEN:?set SERVANT_TOKEN}"
[ $# -gt 0 ] || { echo "usage: push.sh [claude|cursor] <file>..." >&2; exit 1; }

remote_path() {
  local file
  file=$(realpath -s "$1")
  case "$file" in
    "$HOME/.claude/projects/"*/memory/*) echo "memory/$project/${file##*/memory/}" ;;
    "$HOME/.claude/skills/"*) echo "skills/$tool/${file#"$HOME/.claude/skills/"}" ;;
    "$HOME/.cursor/skills-cursor/"*) echo "skills/$tool/${file#"$HOME/.cursor/skills-cursor/"}" ;;
    */.cursor/rules/*) echo "rules/$project/${file##*/.cursor/rules/}" ;;
  esac
}

for file in "$@"; do
  remote=$(remote_path "$file")
  if [ -z "$remote" ]; then
    echo "skipped      $file (not a memory, skill or rule file)" >&2
    continue
  fi
  jq -n --arg path "$remote" --rawfile body "$file" '{files: [{path: $path, body: $body}]}' |
    curl -sSf -H "Authorization: Bearer $SERVANT_TOKEN" -H 'Content-Type: application/json' \
      -d @- "$SERVANT_URL/api/agent_memory" > /dev/null
  echo "pushed       $remote"
done
```

Then `chmod +x docs/skills/servant-memory/scripts/*.sh`.

- [ ] **Step 3: Write `SKILL.md`**

`docs/skills/servant-memory/SKILL.md`:

```markdown
---
name: servant-memory
description: Use at the start of every session and after writing any memory file, skill or Cursor rule. Pulls the agent memory and skills of the current repo from Servant and pushes local changes back, so the desktop and the laptop share one memory.
---

# Servant memory sync

Your memory (`~/.claude/projects/<cwd>/memory/*.md`), your skills
(`~/.claude/skills/*`, `~/.cursor/skills-cursor/*`) and the repo's Cursor rules
(`.cursor/rules/*.mdc`) live in Servant's Agent memory app, keyed by path:

| remote path | local file |
|-------------|------------|
| `memory/<project>/<file>.md` | `~/.claude/projects/<mangled cwd>/memory/<file>.md` |
| `skills/claude/<name>/…` | `~/.claude/skills/<name>/…` |
| `skills/cursor/<name>/…` | `~/.cursor/skills-cursor/<name>/…` |
| `skills/shared/<name>/…` | the current tool's skills dir |
| `rules/<project>/<file>.mdc` | `<repo>/.cursor/rules/<file>.mdc` |

`<project>` is `basename "$PWD"`, so run the scripts from the repo root.

## Setup (once per machine)

1. In Servant, Settings > API tokens: create a token with the `Agent memory: write` scope.
2. Export `SERVANT_URL` (e.g. `https://servant.example.com`) and `SERVANT_TOKEN` (the `srv_` token) in the shell profile.
3. Copy this folder to `~/.claude/skills/servant-memory/` and `~/.cursor/skills-cursor/servant-memory/`.
4. Seed once from each repo: `scripts/push.sh claude ~/.claude/projects/$(pwd | tr / -)/memory/*.md ~/.claude/skills/*/SKILL.md`.

## Session start: pull

Run, from the repo root, with `claude` or `cursor` depending on who you are:

```bash
~/.claude/skills/servant-memory/scripts/pull.sh claude
```

It writes every remote file that is missing locally or newer than the local copy
and prints `LOCAL NEWER <path>` for files you changed here since the last push.
For those, push them (below), or when the remote copy also changed, read both,
merge by hand (they are markdown), write the merge locally and push it.

## After every write: push

Right after saving a memory file, a skill file or a Cursor rule:

```bash
~/.claude/skills/servant-memory/scripts/push.sh claude <the file you wrote>
```

Several files can be pushed in one call. Do this in the same turn as the write,
not at the end of the session.

## Rules

- Never push a file outside the three trees, the server rejects other paths anyway.
- Never write secrets (tokens, passwords, keys) in a memory file: it is stored server side and readable in the app.
- Deleting is done from the app, not from here; a file deleted locally is simply not pulled back until someone deletes it remotely too.
- If `SERVANT_URL` or `SERVANT_TOKEN` is unset, say so once and carry on without syncing.
```

- [ ] **Step 4: Point the docs at the skill**

In `CLAUDE.md`, under "See also (not auto-loaded)", add:

```markdown
- `docs/skills/servant-memory/SKILL.md`: the skill (plus pull/push scripts) that lets Claude Code and Cursor share agent memory and skills through the Agent memory app.
```

- [ ] **Step 5: Smoke-test the scripts against the dev server**

With `mix phx.server` running and a token created in Settings (scope Agent memory: write):

```bash
export SERVANT_URL=http://localhost:4001 SERVANT_TOKEN=srv_...
cd /home/frankrousseau/perso/servant-elixir
docs/skills/servant-memory/scripts/push.sh claude ~/.claude/projects/$(pwd | tr / -)/memory/MEMORY.md
docs/skills/servant-memory/scripts/pull.sh claude
```

Expected: `pushed       memory/servant-elixir/MEMORY.md`, then the pull prints nothing (hash identical). Touch a different body remotely from the app's Edit button and pull again: `pulled       memory/servant-elixir/MEMORY.md` and the local file matches. Restore your real MEMORY.md afterwards (`git` does not track it; re-edit from the app or push again).

- [ ] **Step 6: Commit**

```bash
git add docs/skills/servant-memory CLAUDE.md
git commit -m "docs: servant-memory skill with pull and push scripts"
```

---

### Task 7: Precommit and wrap-up

**Files:** none new.

- [ ] **Step 1: Run the full checks**

Run: `mix precommit && cd frontend && npm run format && npm test`
Expected: compile without warnings, format clean, all tests PASS. Fix anything reported and amend the relevant commit, or add a `fix:` commit.

- [ ] **Step 2: Commit any fixes**

```bash
git add -A lib test frontend/src docs
git commit -m "agent memory: precommit fixes"
```

(Skip if the tree is clean.)
