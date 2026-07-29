defmodule ServantWeb.AiConfigController do
  @moduledoc "Per-user AI agents configuration (Settings > Agents)."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Accounts
  alias ServantWeb.Schemas

  tags(["agents"])

  @config_schema %Schema{
    type: :object,
    properties: %{
      enabled: %Schema{type: :boolean},
      base_url: %Schema{type: :string, description: "OpenAI-compatible base URL"},
      model: %Schema{type: :string},
      api_key: %Schema{type: :string, nullable: true, description: "masked as *** in responses"}
    }
  }

  operation(:show,
    summary: "AI agents configuration",
    description: "Session-only. The API key is masked.",
    responses: [
      ok: {"Config", "application/json", @config_schema},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    json(conn, %{data: Accounts.masked_ai_config(conn.assigns.current_user)})
  end

  operation(:update,
    summary: "Update the AI agents configuration",
    description: "Session-only. Send api_key \"***\" to keep the stored key.",
    request_body: {"Config", "application/json", @config_schema},
    responses: [
      ok: {"Config", "application/json", @config_schema},
      unprocessable_entity: {"Invalid config", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def update(conn, params) do
    case Accounts.update_ai_config(conn.assigns.current_user, params) do
      {:ok, user} ->
        json(conn, %{data: Accounts.masked_ai_config(user)})

      {:error, message} when is_binary(message) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid configuration"})
    end
  end
end
