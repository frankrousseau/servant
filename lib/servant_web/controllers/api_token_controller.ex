defmodule ServantWeb.ApiTokenController do
  @moduledoc "Session-only management of scoped API tokens."

  use ServantWeb, :controller

  alias Servant.ApiTokens
  alias Servant.ApiTokens.ApiToken

  def index(conn, _params) do
    tokens = ApiTokens.list_tokens(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(tokens, &ApiToken.to_json/1)})
  end

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
