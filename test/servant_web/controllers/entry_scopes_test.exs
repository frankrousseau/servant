defmodule ServantWeb.EntryScopesTest do
  use ServantWeb.ConnCase, async: false

  defp seed(user_id) do
    entry_fixture(user_id, %{"kind" => "tracker_log", "title" => "log"})
    entry_fixture(user_id, %{"kind" => "bank_tx", "title" => "tx"})
    entry_fixture(user_id, %{"kind" => "bookmark", "title" => "bm"})
  end

  test "index is restricted to readable kinds" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:read"])
    seed(user.id)

    kinds =
      get(conn, ~p"/api/entries")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["kind"])
      |> Enum.uniq()

    assert kinds == ["tracker_log"]
  end

  test "an explicit kind filter outside the scopes is 403" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:read"])
    seed(user.id)
    conn = get(conn, ~p"/api/entries?kind=bank_tx")
    assert json_response(conn, 403)["required"] == "app:finance:read"
  end

  test "show/delete honor the entry's kind" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])
    tx = entry_fixture(user.id, %{"kind" => "bank_tx"})
    log = entry_fixture(user.id, %{"kind" => "tracker_log"})

    assert json_response(get(conn, ~p"/api/entries/#{tx.id}"), 403)
    assert json_response(get(conn, ~p"/api/entries/#{log.id}"), 200)
    assert json_response(delete(conn, ~p"/api/entries/#{tx.id}"), 403)
    assert response(delete(conn, ~p"/api/entries/#{log.id}"), 204)
  end

  test "create checks the target kind, update checks old and new kind" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:write"])

    conn2 = post(conn, ~p"/api/entries", %{"kind" => "bank_tx", "source" => "api"})
    assert json_response(conn2, 403)["required"] == "app:finance:write"

    conn3 = post(conn, ~p"/api/entries", %{"kind" => "tracker_log", "source" => "api"})
    assert json_response(conn3, 201)

    log = entry_fixture(user.id, %{"kind" => "tracker_log"})
    conn4 = put(conn, ~p"/api/entries/#{log.id}", %{"kind" => "bank_tx"})
    assert json_response(conn4, 403)

    conn5 = put(conn, ~p"/api/entries/#{log.id}", %{"title" => "renamed"})
    assert json_response(conn5, 200)["data"]["title"] == "renamed"
  end

  test "unmapped kinds need data scopes, data:write sees everything" do
    {conn, user} = register_and_log_in_api_token(build_conn(), ["data:write"])
    seed(user.id)

    kinds =
      get(conn, ~p"/api/entries")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["kind"])
      |> Enum.uniq()
      |> Enum.sort()

    assert kinds == ["bank_tx", "bookmark", "tracker_log"]

    assert json_response(
             post(conn, ~p"/api/entries", %{"kind" => "bookmark", "source" => "api"}),
             201
           )
  end

  test "sessions are unaffected" do
    {conn, user} = register_and_log_in_user(build_conn())
    seed(user.id)
    assert length(json_response(get(conn, ~p"/api/entries"), 200)["data"]) == 3
  end
end
