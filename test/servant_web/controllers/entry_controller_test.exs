defmodule ServantWeb.EntryControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "index" do
    test "returns only the caller's entries with pagination meta", %{conn: conn, user: user} do
      entry_fixture(user.id, %{"title" => "Mine"})
      other = user_fixture()
      entry_fixture(other.id, %{"title" => "Theirs"})

      conn = get(conn, "/api/entries")
      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 1
      assert hd(data)["title"] == "Mine"
      assert meta["total"] == 1
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/entries")
      assert json_response(conn, 401)
    end
  end

  describe "create" do
    test "201 with valid params", %{conn: conn} do
      conn = post(conn, "/api/entries", %{"kind" => "note", "source" => "ui", "title" => "Hi"})
      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Hi"
      assert data["kind"] == "note"
    end

    test "422 when required fields are missing", %{conn: conn} do
      conn = post(conn, "/api/entries", %{"title" => "no kind/source"})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "show / update / delete scoping" do
    test "shows the caller's own entry", %{conn: conn, user: user} do
      entry = entry_fixture(user.id, %{"title" => "Readable"})
      conn = get(conn, "/api/entries/#{entry.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == entry.id
    end

    test "404 when showing another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> get(conn, "/api/entries/#{foreign.id}") end)
    end

    test "updates the caller's own entry", %{conn: conn, user: user} do
      entry = entry_fixture(user.id, %{"title" => "Before"})
      conn = put(conn, "/api/entries/#{entry.id}", %{"title" => "After"})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "After"
    end

    test "404 when updating another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> put(conn, "/api/entries/#{foreign.id}", %{"title" => "x"}) end)
    end

    test "refuses to update a note through the generic entries API", %{conn: conn, user: user} do
      note = entry_fixture(user.id, %{"kind" => "note", "source" => "notes"})
      conn = put(conn, "/api/entries/#{note.id}", %{"title" => "hijacked"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "deletes the caller's own entry (204)", %{conn: conn, user: user} do
      entry = entry_fixture(user.id)
      conn = delete(conn, "/api/entries/#{entry.id}")
      assert response(conn, 204)
    end

    test "404 when deleting another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> delete(conn, "/api/entries/#{foreign.id}") end)
    end
  end
end
