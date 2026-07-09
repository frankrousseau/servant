defmodule ServantWeb.NotesController do
  @moduledoc "Notes CRUD through the Notes context (wikilinks, backlinks)."

  use ServantWeb, :controller

  alias Servant.Data.Entry
  alias Servant.Notes

  plug ServantWeb.Plugs.Scope, domain: "notes"

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    notes = Notes.list_notes(user_id)
    json(conn, %{data: Enum.map(notes, &Entry.to_json/1)})
  end

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    note = Notes.get_note!(user_id, id)
    json(conn, %{data: Entry.to_json(note)})
  end

  def backlinks(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    note = Notes.get_note!(user_id, id)
    backlinks = Notes.backlinks(user_id, note)
    json(conn, %{data: Enum.map(backlinks, &Entry.to_json/1)})
  end

  def mentioning(conn, %{"entry_id" => entry_id}) do
    user_id = conn.assigns.current_user.id
    notes = Notes.mentioning(user_id, entry_id)
    json(conn, %{data: Enum.map(notes, &Entry.to_json/1)})
  end

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Notes.create_note(user_id, params) do
      {:ok, note} ->
        conn
        |> put_status(:created)
        |> json(%{data: Entry.to_json(note)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    case Notes.update_note(user_id, id, params) do
      {:ok, note} ->
        json(conn, %{data: Entry.to_json(note)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Notes.delete_note(user_id, id) do
      {:ok, _note} ->
        send_resp(conn, :no_content, "")

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not delete note"})
    end
  end
end
