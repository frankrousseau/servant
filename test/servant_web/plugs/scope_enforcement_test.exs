defmodule ServantWeb.ScopeEnforcementTest do
  use ServantWeb.ConnCase, async: false

  describe "notes" do
    test "app:notes:read can list but not create" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:notes:read"])
      assert json_response(get(conn, ~p"/api/notes"), 200)

      conn = post(conn, ~p"/api/notes", %{"title" => "x", "body" => ""})
      assert json_response(conn, 403)["required"] == "app:notes:write"
    end

    test "app:notes:write can create" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:notes:write"])
      conn = post(conn, ~p"/api/notes", %{"title" => "from agent", "body" => "hello"})
      assert json_response(conn, 201)["data"]["title"] == "from agent"
    end

    test "a foreign-domain token gets 403 on notes" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
      assert json_response(get(conn, ~p"/api/notes"), 403)
    end
  end

  describe "uploads" do
    # async: false at module level. This setup mutates the FILES_DIR env var,
    # the same as UploadControllerTest.
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "servant_scope_upload_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      prev = System.get_env("FILES_DIR")
      System.put_env("FILES_DIR", dir)

      on_exit(fn ->
        if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
        File.rm_rf(dir)
      end)

      :ok
    end

    test "app:photos:write can upload to photos, not to files" do
      upload = %Plug.Upload{
        path: write_tmp!("x"),
        content_type: "text/plain",
        filename: "x.txt"
      }

      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:photos:write"])

      assert json_response(
               post(conn, ~p"/api/uploads", %{"file" => upload, "app" => "photos"}),
               200
             )

      {conn2, _user2} = register_and_log_in_api_token(build_conn(), ["app:photos:write"])
      conn2 = post(conn2, ~p"/api/uploads", %{"file" => upload, "app" => "files"})
      assert json_response(conn2, 403)["required"] == "app:files:write"
    end
  end

  describe "meta endpoints and exports need data:read" do
    test "kind-scoped tokens are refused" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
      assert json_response(get(conn, ~p"/api/entries/stats"), 403)
      assert json_response(get(conn, ~p"/api/entries/kinds"), 403)
      assert response(get(conn, ~p"/api/export/entries"), 403)
    end

    test "data:read passes" do
      {conn, _user} = register_and_log_in_api_token(build_conn(), ["data:read"])
      assert json_response(get(conn, ~p"/api/entries/stats"), 200)
    end
  end

  defp write_tmp!(content) do
    path = Path.join(System.tmp_dir!(), "scope-test-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    path
  end
end
