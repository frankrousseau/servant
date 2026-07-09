defmodule ServantWeb.ApiTokenControllerTest do
  use ServantWeb.ConnCase, async: false

  test "create returns the plaintext once, list never does", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)

    created =
      conn
      |> post(~p"/api/tokens", %{"name" => "my agent", "scopes" => ["app:notes:write"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert String.starts_with?(created["token"], "srv_")
    assert created["scopes"] == ["app:notes:write"]

    listed = json_response(get(conn, ~p"/api/tokens"), 200)["data"]
    assert [%{"name" => "my agent"} = row] = listed
    refute Map.has_key?(row, "token")
    refute Map.has_key?(row, "token_hash")
  end

  test "invalid scopes are rejected", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    conn = post(conn, ~p"/api/tokens", %{"name" => "x", "scopes" => ["nope"]})
    assert json_response(conn, 422)["errors"]["scopes"]
  end

  test "delete revokes", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)

    created =
      conn
      |> post(~p"/api/tokens", %{"name" => "t", "scopes" => ["data:read"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert response(delete(conn, ~p"/api/tokens/#{created["id"]}"), 204)

    probe = build_conn() |> put_req_header("authorization", "Bearer #{created["token"]}")
    assert json_response(get(probe, ~p"/api/entries"), 401)
  end

  test "an API token cannot manage tokens (no escalation)", %{conn: conn} do
    {conn, _user} = register_and_log_in_api_token(conn, ["data:write"])
    assert json_response(get(conn, ~p"/api/tokens"), 403)

    conn = post(conn, ~p"/api/tokens", %{"name" => "evil", "scopes" => ["data:write"]})
    assert json_response(conn, 403)
  end
end
