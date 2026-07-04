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
  end
end
