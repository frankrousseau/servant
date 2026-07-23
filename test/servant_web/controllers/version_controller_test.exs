defmodule ServantWeb.VersionControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "returns the backend build info", %{conn: conn} do
    conn = get(conn, "/api/version")
    assert %{"commit" => commit, "built_at" => built_at} = json_response(conn, 200)
    assert is_binary(commit)
    assert commit != ""
    assert built_at =~ ~r/^\d{4}-\d{2}-\d{2}$/
  end

  test "401 without a token" do
    conn = get(build_conn(), "/api/version")
    assert json_response(conn, 401)
  end
end
