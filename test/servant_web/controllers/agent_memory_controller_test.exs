defmodule ServantWeb.AgentMemoryControllerTest do
  use ServantWeb.ConnCase

  alias Servant.AgentMemory
  alias Servant.Data.Entry
  alias Servant.Repo

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

    test "422 when the path conflicts with a differently-kinded entry", %{
      conn: conn,
      user: user
    } do
      {:ok, _entry} =
        %Entry{user_id: user.id}
        |> Entry.changeset(%{
          "kind" => "bookmark",
          "source" => "agent",
          "external_id" => "memory/p/a.md"
        })
        |> Repo.insert()

      conn =
        post(conn, ~p"/api/agent_memory", %{
          "files" => [%{"path" => "memory/p/a.md", "body" => "x"}]
        })

      assert json_response(conn, 422)["error"] =~ "conflict"
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
