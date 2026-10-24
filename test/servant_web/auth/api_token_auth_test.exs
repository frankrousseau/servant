defmodule ServantWeb.Auth.ApiTokenAuthTest do
  use ServantWeb.ConnCase, async: false

  alias Servant.Auth.Throttle

  setup do
    # The failed lookups feed the per-IP throttle. Keep the tests independent.
    on_exit(fn -> Throttle.reset("api_token:127.0.0.1") end)
    :ok
  end

  test "a valid API token authenticates", %{conn: conn} do
    {conn, _user} = register_and_log_in_api_token(conn, ["data:read"])
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 200)
  end

  test "an unknown srv_ token gets 401 and records a throttle failure", %{conn: conn} do
    conn = put_req_header(conn, "authorization", "Bearer srv_unknown")
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 401)["error"] == "Unauthorized"
  end

  test "too many failed srv_ attempts get 429", %{conn: conn} do
    for _ <- 1..10, do: Throttle.record_failure("api_token:127.0.0.1")

    conn = put_req_header(conn, "authorization", "Bearer srv_unknown")
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 429)["error"] == "Too many attempts"
  end

  test "session tokens keep full access (api_scopes nil)", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    conn = get(conn, ~p"/api/entries")
    assert json_response(conn, 200)
  end
end
