defmodule ServantWeb.PhotoShareController do
  @moduledoc "Session-only management of public photo-feed links (Photos app > Share)."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.PhotoShares
  alias Servant.PhotoShares.PhotoShare
  alias ServantWeb.Schemas

  tags(["photo shares"])

  operation(:index,
    summary: "List photo-feed links",
    description: "Session-only. Every link the user created, newest first.",
    responses: [
      ok:
        {"Shares", "application/json",
         %Schema{
           type: :object,
           properties: %{data: %Schema{type: :array, items: Schemas.PhotoShare}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    shares = PhotoShares.list_shares(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(shares, &PhotoShare.to_json/1)})
  end

  operation(:create,
    summary: "Create a photo-feed link",
    description:
      "Session-only. Anyone opening `/share/<token>` then sees the photos carrying the tags or people (any of them, or all of them with `match: all`); the feed follows later tag changes. At least one tag or person is required.",
    request_body:
      {"Share attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           name: %Schema{type: :string, nullable: true},
           tags: %Schema{type: :array, items: %Schema{type: :string}},
           people: %Schema{
             type: :array,
             items: %Schema{
               type: :object,
               properties: %{id: %Schema{type: :string}, name: %Schema{type: :string}},
               required: [:id]
             }
           },
           match: %Schema{type: :string, enum: ["any", "all"]}
         }
       }},
    responses: [
      created:
        {"Share", "application/json",
         %Schema{type: :object, properties: %{data: Schemas.PhotoShare}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    case PhotoShares.create_share(conn.assigns.current_user.id, params) do
      {:ok, share} ->
        conn
        |> put_status(:created)
        |> json(%{data: PhotoShare.to_json(share)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:delete,
    summary: "Revoke a photo-feed link",
    description: "Session-only. The public page and its files stop resolving at once.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Revoked",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    case PhotoShares.delete_share(conn.assigns.current_user.id, id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
