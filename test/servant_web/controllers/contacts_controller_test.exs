defmodule ServantWeb.ContactsControllerTest do
  use ServantWeb.ConnCase, async: false

  defp contact(user_id, name, data \\ %{}) do
    entry_fixture(user_id, %{
      "kind" => "contact",
      "source" => "manual",
      "title" => name,
      "data" => Map.put(data, "display_name", name)
    })
  end

  test "merges duplicates into the survivor", %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    keep = contact(user.id, "Alice")
    dup = contact(user.id, "Alice M.", %{"org" => "ACME"})

    merged =
      conn
      |> post(~p"/api/contacts/merge", %{"survivor_id" => keep.id, "duplicate_ids" => [dup.id]})
      |> json_response(200)
      |> Map.fetch!("data")

    assert merged["id"] == keep.id
    assert merged["data"]["org"] == "ACME"
    refute Servant.Repo.get(Servant.Data.Entry, dup.id)
  end

  test "422 on an invalid merge", %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    keep = contact(user.id, "Alice")

    conn =
      post(conn, ~p"/api/contacts/merge", %{
        "survivor_id" => keep.id,
        "duplicate_ids" => [keep.id]
      })

    assert json_response(conn, 422)["error"] =~ "survivor"
  end

  test "needs contacts write scope for an API token", %{conn: conn} do
    {conn, user} = register_and_log_in_api_token(conn, ["app:contacts:read"])
    keep = contact(user.id, "Alice")
    dup = contact(user.id, "Alice M.")

    conn =
      post(conn, ~p"/api/contacts/merge", %{
        "survivor_id" => keep.id,
        "duplicate_ids" => [dup.id]
      })

    assert json_response(conn, 403)["required"] == "app:contacts:write"
  end
end
