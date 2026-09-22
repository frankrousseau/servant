defmodule ServantWeb.PhotoShareControllerTest do
  use ServantWeb.ConnCase, async: false

  test "create, list and revoke a link", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)

    created =
      conn
      |> post(~p"/api/photo_shares", %{"name" => "Summer", "tags" => ["beach"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert created["name"] == "Summer"
    assert created["tags"] == ["beach"]
    assert created["match"] == "any"
    assert created["path"] == "/share/#{created["token"]}"

    assert [%{"id" => id}] = json_response(get(conn, ~p"/api/photo_shares"), 200)["data"]
    assert id == created["id"]

    assert response(delete(conn, ~p"/api/photo_shares/#{id}"), 204)
    assert json_response(get(conn, ~p"/api/photo_shares"), 200)["data"] == []
    assert json_response(get(build_conn(), ~p"/api/shares/#{created["token"]}"), 404)
  end

  test "an empty tag list is rejected", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    # Rejected by the spec validation before the action runs.
    conn = post(conn, ~p"/api/photo_shares", %{"tags" => []})
    assert json_response(conn, 422)["error"] =~ "tags"
  end

  test "API tokens cannot manage links (session only)", %{conn: conn} do
    {conn, _user} = register_and_log_in_api_token(conn, ["data:write"])
    assert json_response(get(conn, ~p"/api/photo_shares"), 403)
    assert json_response(post(conn, ~p"/api/photo_shares", %{"tags" => ["x"]}), 403)
  end

  test "links are listed per user", %{conn: conn} do
    {owner_conn, _owner} = register_and_log_in_user(conn)
    {other_conn, _other} = register_and_log_in_user(conn)

    created =
      owner_conn
      |> post(~p"/api/photo_shares", %{"tags" => ["beach"]})
      |> json_response(201)
      |> Map.fetch!("data")

    assert json_response(get(other_conn, ~p"/api/photo_shares"), 200)["data"] == []
    assert json_response(delete(other_conn, ~p"/api/photo_shares/#{created["id"]}"), 404)
  end
end
