defmodule ServantWeb.NotesControllerTest do
  use ServantWeb.ConnCase

  alias Servant.Notes

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "index" do
    test "returns only the caller's notes", %{conn: conn, user: user} do
      {:ok, _} = Notes.create_note(user.id, %{"title" => "Mine", "body" => ""})
      other = user_fixture()
      {:ok, _} = Notes.create_note(other.id, %{"title" => "Theirs", "body" => ""})

      conn = get(conn, "/api/notes")
      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["title"]) == ["Mine"]
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/notes")
      assert json_response(conn, 401)
    end
  end

  describe "create" do
    test "201 and derives slug/tags", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          "title" => "Hello",
          "folder" => "Inbox",
          "body" => "hi #tag"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["kind"] == "note"
      assert data["external_id"] == "inbox/hello"
      assert data["data"]["tags"] == ["tag"]
    end

    test "422 when title yields an empty slug", %{conn: conn} do
      conn = post(conn, "/api/notes", %{"title" => "", "body" => ""})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "backlinks" do
    test "lists notes that link to the target", %{conn: conn, user: user} do
      {:ok, target} = Notes.create_note(user.id, %{"title" => "Target", "body" => ""})
      {:ok, source} = Notes.create_note(user.id, %{"title" => "Source", "body" => "[[Target]]"})

      conn = get(conn, "/api/notes/#{target.id}/backlinks")
      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data, & &1["id"]) == [source.id]
    end
  end

  describe "show / update / delete scoping" do
    test "404 when showing another user's note", %{conn: conn} do
      other = user_fixture()
      {:ok, foreign} = Notes.create_note(other.id, %{"title" => "X", "body" => ""})
      assert_error_sent(404, fn -> get(conn, "/api/notes/#{foreign.id}") end)
    end

    test "updates and deletes the caller's note", %{conn: conn, user: user} do
      {:ok, note} = Notes.create_note(user.id, %{"title" => "Before", "body" => ""})

      conn = put(conn, "/api/notes/#{note.id}", %{"title" => "After", "body" => "x"})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "After"

      conn = delete(conn, "/api/notes/#{note.id}")
      assert response(conn, 204)
    end
  end
end
