defmodule ServantWeb.FilesControllerTest do
  use ServantWeb.ConnCase

  alias ServantWeb.Auth

  setup do
    dir =
      Path.join(System.tmp_dir!(), "servant_files_ctrl_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    prev = System.get_env("FILES_DIR")
    System.put_env("FILES_DIR", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp write_file(dir, user_id, rel, content) do
    absolute = Path.join([dir, user_id, rel])
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)
    # relative path under FILES_DIR, as it appears in a /files/ URL
    Path.join([user_id, rel])
  end

  defp with_cookie(conn, user_id) do
    token = Auth.sign_token(ServantWeb.Endpoint, user_id)
    Plug.Test.put_req_cookie(conn, Auth.auth_cookie_name(), token)
  end

  test "serves the owner's file with a valid cookie", %{conn: conn, dir: dir} do
    user = user_fixture()
    rel = write_file(dir, user.id, "apps/files/hello.txt", "hi there")

    conn = conn |> with_cookie(user.id) |> get("/files/#{rel}")
    assert response(conn, 200) == "hi there"
  end

  test "401 without a cookie", %{conn: conn, dir: dir} do
    user = user_fixture()
    rel = write_file(dir, user.id, "apps/files/hello.txt", "hi")

    conn = get(conn, "/files/#{rel}")
    assert json_response(conn, 401)
  end

  test "404 for another user's file (ownership enforced)", %{conn: conn, dir: dir} do
    owner = user_fixture()
    other = user_fixture()
    rel = write_file(dir, owner.id, "apps/files/secret.txt", "bank statement")

    conn = conn |> with_cookie(other.id) |> get("/files/#{rel}")
    assert json_response(conn, 404)
  end

  test "404 for a non-existent file the user could otherwise own", %{conn: conn} do
    user = user_fixture()
    conn = conn |> with_cookie(user.id) |> get("/files/#{user.id}/apps/files/missing.txt")
    assert json_response(conn, 404)
  end
end
