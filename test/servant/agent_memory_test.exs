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
        assert AgentMemory.parse_path(path) == {:error, :invalid_path}
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
