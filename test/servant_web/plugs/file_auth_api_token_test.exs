defmodule ServantWeb.Plugs.FileAuthApiTokenTest do
  use ServantWeb.ConnCase

  alias Servant.ApiTokens

  setup do
    dir =
      Path.join(System.tmp_dir!(), "servant_file_auth_tok_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    prev = System.get_env("FILES_DIR")
    System.put_env("FILES_DIR", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
      File.rm_rf(dir)
      Servant.Auth.Throttle.reset("api_token:127.0.0.1")
    end)

    %{dir: dir}
  end

  defp write_file(dir, user_id, rel, content) do
    absolute = Path.join([dir, user_id, rel])
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)
    Path.join([user_id, rel])
  end

  defp bearer(conn, user_id, scopes) do
    {:ok, _token, plaintext} =
      ApiTokens.create_token(user_id, %{"name" => "files bot", "scopes" => scopes})

    put_req_header(conn, "authorization", "Bearer #{plaintext}")
  end

  test "a token with data:read-binary downloads the owner's file", %{conn: conn, dir: dir} do
    user = user_fixture()
    rel = write_file(dir, user.id, "apps/photos/pic.jpg", "jpeg bytes")

    conn = conn |> bearer(user.id, ["data:read-binary"]) |> get("/files/#{rel}")
    assert response(conn, 200) == "jpeg bytes"
  end

  test "a token without data:read-binary gets 403 with the required scope", %{
    conn: conn,
    dir: dir
  } do
    user = user_fixture()
    rel = write_file(dir, user.id, "apps/files/doc.txt", "secret")

    conn = conn |> bearer(user.id, ["data:write"]) |> get("/files/#{rel}")
    assert json_response(conn, 403)["required"] == "data:read-binary"
  end

  test "an unknown srv_ token gets 401", %{conn: conn, dir: dir} do
    user = user_fixture()
    rel = write_file(dir, user.id, "apps/files/doc.txt", "secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer srv_unknown")
      |> get("/files/#{rel}")

    assert json_response(conn, 401)
  end

  test "ownership still holds: another user's file is 404", %{conn: conn, dir: dir} do
    owner = user_fixture()
    other = user_fixture()
    rel = write_file(dir, owner.id, "apps/files/secret.txt", "bank statement")

    conn = conn |> bearer(other.id, ["data:read-binary"]) |> get("/files/#{rel}")
    assert json_response(conn, 404)
  end
end
