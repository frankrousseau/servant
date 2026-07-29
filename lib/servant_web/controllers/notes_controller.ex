defmodule ServantWeb.NotesController do
  @moduledoc "Notes CRUD through the Notes context (wikilinks, backlinks)."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Data.Entry
  alias Servant.Notes
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.Scope, domain: "notes"

  tags(["notes"])

  @note_list %Schema{
    type: :object,
    properties: %{data: %Schema{type: :array, items: Schemas.Entry}}
  }
  @note_envelope %Schema{type: :object, properties: %{data: Schemas.Entry}}

  operation(:index,
    summary: "List notes",
    description: "Requires app:notes:read for an API token.",
    responses: [
      ok: {"Notes", "application/json", @note_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    notes = Notes.list_notes(user_id)
    json(conn, %{data: Enum.map(notes, &Entry.to_json/1)})
  end

  operation(:show,
    summary: "Get one note",
    description: "Requires app:notes:read for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Note", "application/json", @note_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    note = Notes.get_note!(user_id, id)
    json(conn, %{data: Entry.to_json(note)})
  end

  operation(:backlinks,
    summary: "List notes linking to this note",
    description: "Requires app:notes:read for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Notes", "application/json", @note_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def backlinks(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    note = Notes.get_note!(user_id, id)
    backlinks = Notes.backlinks(user_id, note)
    json(conn, %{data: Enum.map(backlinks, &Entry.to_json/1)})
  end

  operation(:mentioning,
    summary: "List notes mentioning an entry",
    description:
      "Notes with an @[[mention]] of the given entry (contact or event). Requires app:notes:read for an API token.",
    parameters: [entry_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Notes", "application/json", @note_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def mentioning(conn, %{"entry_id" => entry_id}) do
    user_id = conn.assigns.current_user.id
    notes = Notes.mentioning(user_id, entry_id)
    json(conn, %{data: Enum.map(notes, &Entry.to_json/1)})
  end

  operation(:create,
    summary: "Create a note",
    description:
      "Parses [[wikilinks]], @[[mentions]] and #tags on save. Requires app:notes:write for an API token.",
    request_body:
      {"Note attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           title: %Schema{type: :string},
           data: %Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: [
      created: {"Note", "application/json", @note_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

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

  operation(:update,
    summary: "Update a note",
    description:
      "Renames propagate to referring notes' wikilinks. Requires app:notes:write for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Note attributes", "application/json",
       %Schema{type: :object, properties: %{}, additionalProperties: true}},
    responses: [
      ok: {"Note", "application/json", @note_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete,
    summary: "Delete a note",
    description: "Requires app:notes:write for an API token.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Delete failed", "application/json", Schemas.Error}
    ]
  )

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
