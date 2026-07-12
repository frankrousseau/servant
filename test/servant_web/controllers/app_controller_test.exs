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

      # Each app carries the fields the SPA needs to render/route it.
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
