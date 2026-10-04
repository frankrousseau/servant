defmodule ServantWeb.ContactsController do
  @moduledoc "Contact-specific operations beyond entry CRUD: the merge of duplicates."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Contacts
  alias Servant.Data.Entry
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.Scope, domain: "contacts"

  tags(["contacts"])

  operation(:merge,
    summary: "Merge duplicate contacts",
    description:
      "Merges `duplicate_ids` into `survivor_id`: the survivor keeps its values and takes the duplicates' where it had none (emails, phones, tags and relations are unioned), every reference to a duplicate (events, photo faces, birthday and me prefs, relations, note mentions) is repointed at the survivor, and the duplicates are deleted. Requires app:contacts:write for an API token.",
    request_body:
      {"Merge request", "application/json",
       %Schema{
         type: :object,
         properties: %{
           survivor_id: %Schema{type: :string, format: :uuid},
           duplicate_ids: %Schema{
             type: :array,
             items: %Schema{type: :string, format: :uuid},
             minItems: 1
           }
         },
         required: [:survivor_id, :duplicate_ids]
       }},
    responses: [
      ok:
        {"The merged contact", "application/json",
         %Schema{type: :object, properties: %{data: Schemas.Entry}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid merge", "application/json", Schemas.Error}
    ]
  )

  def merge(conn, %{"survivor_id" => survivor_id, "duplicate_ids" => duplicate_ids}) do
    case Contacts.merge(conn.assigns.current_user.id, survivor_id, duplicate_ids) do
      {:ok, survivor} ->
        json(conn, %{data: Entry.to_json(survivor)})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end
end
