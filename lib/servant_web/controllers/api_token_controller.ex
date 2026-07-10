defmodule ServantWeb.ApiTokenController do
  @moduledoc "Session-only management of scoped API tokens."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Servant.ApiTokens
  alias Servant.ApiTokens.ApiToken
  alias ServantWeb.Schemas

  tags(["tokens"])

  operation(:index,
    summary: "List API tokens",
    description: "Session-only (API tokens cannot manage other tokens). Never returns plaintext.",
    responses: [
      ok:
        {"Tokens", "application/json",
         %Schema{
           type: :object,
           properties: %{data: %Schema{type: :array, items: Schemas.ApiToken}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    tokens = ApiTokens.list_tokens(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(tokens, &ApiToken.to_json/1)})
  end

  operation(:create,
    summary: "Create an API token",
    description:
      "Session-only. The plaintext token is returned once, in this response only; only its SHA-256 hash is stored.",
    request_body:
      {"Token attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           name: %Schema{type: :string},
           scopes: %Schema{type: :array, items: %Schema{type: :string}},
           expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
         },
         required: [:name, :scopes]
       }},
    responses: [
      created:
        {"Token", "application/json",
         %Schema{type: :object, properties: %{data: Schemas.ApiToken}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    case ApiTokens.create_token(conn.assigns.current_user.id, params) do
      {:ok, api_token, plaintext} ->
        conn
        |> put_status(:created)
        |> json(%{data: Map.put(ApiToken.to_json(api_token), :token, plaintext)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:delete,
    summary: "Revoke an API token",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Revoked",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    case ApiTokens.delete_token(conn.assigns.current_user.id, id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
