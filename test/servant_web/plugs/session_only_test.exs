defmodule ServantWeb.Plugs.SessionOnlyTest do
  use ServantWeb.ConnCase, async: false

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_api_token(conn, ["data:write"])
    %{conn: conn, user: user}
  end

  test "API tokens cannot reach auth endpoints", %{conn: conn} do
    conn = get(conn, ~p"/api/auth/me")
    assert json_response(conn, 403)
  end

  test "API tokens cannot manage connectors", %{conn: conn} do
    conn = get(conn, ~p"/api/connectors")
    assert json_response(conn, 403)
  end

  test "API tokens cannot start a media backfill", %{conn: conn} do
    conn = post(conn, ~p"/api/entries/backfill_media")
    assert json_response(conn, 403)
  end

  test "sessions still reach session-only endpoints" do
    {conn, _user} = register_and_log_in_user(build_conn())
    conn = get(conn, ~p"/api/auth/me")
    assert json_response(conn, 200)
  end
end
