defmodule ServantWeb.AppControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "index" do
    test "lists the built-in apps", %{conn: conn} do
      conn = get(conn, "/api/apps")
      assert %{"data" => apps} = json_response(conn, 200)

      ids = Enum.map(apps, & &1["id"])
      assert "contacts" in ids
      assert "calendar" in ids
      assert "files" in ids
      assert "photos" in ids
      assert "notes" in ids

      # Each app carries the fields that are necessary for the SPA to render it
      # and route it.
      for app <- apps do
        assert is_binary(app["name"])
        assert is_binary(app["route"])
        assert app["built_in"] == true
      end
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/apps")
      assert json_response(conn, 401)
    end

    test "includes installed apps with their entry_url", %{conn: conn, user: user} do
      install_fixture_app(user)

      conn = get(conn, "/api/apps")
      %{"data" => apps} = json_response(conn, 200)

      app = Enum.find(apps, &(&1["id"] == "todo-plus"))
      assert app["built_in"] == false
      assert app["route"] == "/apps/todo-plus"
      assert app["entry_url"] == "/files/#{user.id}/installed_apps/todo-plus/dist/index.js"
    end
  end

  describe "create" do
    test "422 with a clear message on invalid repo_url", %{conn: conn} do
      conn = post(conn, "/api/apps", %{repo_url: "git@github.com:a/b.git"})
      assert %{"error" => msg} = json_response(conn, 422)
      assert msg =~ "https"
    end
  end

  describe "delete" do
    test "uninstalls an app", %{conn: conn, user: user} do
      install_fixture_app(user)

      conn = delete(conn, "/api/apps/todo-plus")
      assert response(conn, 204)
      assert Servant.Apps.list_apps(user.id) == []
    end

    test "404 for unknown apps", %{conn: conn} do
      conn = delete(conn, "/api/apps/nope")
      assert json_response(conn, 404)
    end
  end

  describe "builder agent endpoints" do
    defp enable_agents(user) do
      {:ok, user} =
        Servant.Accounts.update_ai_config(user, %{
          "enabled" => true,
          "model" => "test-model",
          # Closed port: the task fails fast and the run gets the "error" status.
          # This test never examines that final status.
          "base_url" => "http://localhost:9/v1"
        })

      user
    end

    test "403 on every agent route when agents are disabled", %{conn: conn} do
      assert conn
             |> post("/api/apps/generate", %{"name" => "X", "description" => "y"})
             |> json_response(403)

      assert conn |> post("/api/apps/x/modify", %{"instruction" => "y"}) |> json_response(403)
      assert conn |> post("/api/apps/x/restore") |> json_response(403)
    end

    test "generate returns 202 with a pollable run", %{conn: conn, user: user} do
      enable_agents(user)

      conn = post(conn, "/api/apps/generate", %{"name" => "My Todo", "description" => "todos"})
      assert %{"data" => %{"id" => run_id, "status" => "running"}} = json_response(conn, 202)

      conn = get(conn, "/api/agents/runs/#{run_id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["action"] == "create"
      assert data["model"] == "test-model"
      assert data["app_id"] == "my-todo"

      wait_for_agent_tasks()
    end

    test "generate rejects an invalid name", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/generate", %{"name" => "!!!", "description" => "y"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "modify 404s on an unknown app", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/nope/modify", %{"instruction" => "x"})
      assert json_response(conn, 404)
    end

    test "restore surfaces Apps errors", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/nope/restore")
      assert json_response(conn, 404)
    end

    test "GET /api/apps/runs is gone (moved to /api/agents/runs)", %{conn: conn} do
      # No route matches "/api/apps/runs" anymore. As a result, the request
      # falls through to the SPA catch-all. There is no NoRouteError to catch
      # with assert_error_sent, because the router has a wildcard "/*path" route.
      conn = get(conn, "/api/apps/runs")
      assert html_response(conn, 200)
    end

    defp wait_for_agent_tasks do
      for pid <- Task.Supervisor.children(Servant.Agents.TaskSupervisor) do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end
    end
  end

  defp install_fixture_app(user) do
    dir = Path.join(System.tmp_dir!(), "servant-app-#{Ecto.UUID.generate()}")
    File.mkdir_p!(Path.join(dir, "dist"))

    manifest = %{"id" => "todo-plus", "name" => "Todo Plus", "entry" => "dist/index.js"}
    File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "dist/index.js"), "export default { mount() {} }")

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(Servant.Storage.join_files([user.id]))
    end)

    {:ok, _} = Servant.Apps.install_from_dir(user.id, dir, "https://example.com/todo.git")
  end
end
