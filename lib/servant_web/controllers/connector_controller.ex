defmodule ServantWeb.ConnectorController do
  @moduledoc "Connector config CRUD and worker start/stop/sync/import."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Connectors
  alias Servant.Connectors.EnableBankingConnector
  alias ServantWeb.Schemas

  tags(["connectors"])

  @config %Schema{
    type: :object,
    description: "Connector configuration.",
    additionalProperties: true
  }
  @config_envelope %Schema{type: :object, properties: %{data: @config}}
  @config_list %Schema{type: :object, properties: %{data: %Schema{type: :array, items: @config}}}

  operation(:index,
    summary: "List connector configs",
    description: "Session-only (API tokens cannot manage connectors).",
    responses: [
      ok: {"Connector configs", "application/json", @config_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    configs = Connectors.list_connector_configs(user_id)
    json(conn, %{data: Enum.map(configs, &config_json/1)})
  end

  operation(:show,
    summary: "Get one connector config",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Connector config", "application/json", @config_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)
    json(conn, %{data: config_json(config)})
  end

  operation(:create,
    summary: "Create a connector config",
    description: "Session-only.",
    request_body:
      {"Connector config attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           connector_type: %Schema{type: :string},
           name: %Schema{type: :string},
           enabled: %Schema{type: :boolean},
           config: %Schema{type: :object, additionalProperties: true},
           schedule: %Schema{type: :string}
         },
         required: [:connector_type, :name]
       }},
    responses: [
      created: {"Connector config", "application/json", @config_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user_id = conn.assigns.current_user.id

    case Connectors.create_connector_config(user_id, params) do
      {:ok, config} ->
        conn
        |> put_status(:created)
        |> json(%{data: config_json(config)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:update,
    summary: "Update a connector config",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Connector config attributes", "application/json",
       %Schema{type: :object, properties: %{}, additionalProperties: true}},
    responses: [
      ok: {"Connector config", "application/json", @config_envelope},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id

    case Connectors.update_connector_config(user_id, id, params) do
      {:ok, config} ->
        json(conn, %{data: config_json(config)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:delete,
    summary: "Delete a connector config",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Delete failed", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Connectors.delete_connector_config(user_id, id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not delete connector config"})
    end
  end

  operation(:sync,
    summary: "Trigger an immediate sync",
    description: "Session-only. The connector must already be running (see start).",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Triggered", "application/json",
         %Schema{type: :object, properties: %{status: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Connector not running", "application/json", Schemas.Error}
    ]
  )

  def sync(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Connectors.sync_now(user_id, id) do
      :ok ->
        json(conn, %{status: "sync_triggered"})

      {:error, :not_running} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Connector is not running. Start it first."})
    end
  end

  operation(:start,
    summary: "Start the connector worker",
    description: "Session-only. Starts the per-user GenServer for this connector config.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Status", "application/json",
         %Schema{type: :object, properties: %{status: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Start failed", "application/json", Schemas.Error}
    ]
  )

  def start(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id

    case Connectors.start_connector(user_id, id) do
      {:ok, _pid} ->
        json(conn, %{status: "started"})

      {:error, {:already_started, _pid}} ->
        json(conn, %{status: "already_running"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  operation(:stop,
    summary: "Stop the connector worker",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Status", "application/json",
         %Schema{type: :object, properties: %{status: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def stop(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    Connectors.stop_connector(user_id, id)
    json(conn, %{status: "stopped"})
  end

  operation(:eb_auth_url,
    summary: "Enable Banking: get the bank authorization URL",
    description:
      "Session-only. Starts the PSD2 consent flow for an enable_banking connector; the user opens the returned URL, approves at the bank and lands back on redirect_url with a code.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Redirect", "application/json",
       %Schema{
         type: :object,
         properties: %{redirect_url: %Schema{type: :string}},
         required: [:redirect_url]
       }},
    responses: [
      ok:
        {"Authorization URL", "application/json",
         %Schema{type: :object, properties: %{url: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Cannot start the flow", "application/json", Schemas.Error}
    ]
  )

  def eb_auth_url(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)
    redirect_url = params["redirect_url"]

    cond do
      config.connector_type != "enable_banking" ->
        unprocessable(conn, "Not an Enable Banking connector")

      not is_binary(redirect_url) or redirect_url == "" ->
        unprocessable(conn, "redirect_url is required")

      true ->
        case EnableBankingConnector.auth_url(config.config || %{}, redirect_url, config.id) do
          {:ok, url} -> json(conn, %{url: url})
          {:error, message} -> unprocessable(conn, message)
        end
    end
  end

  operation(:eb_exchange,
    summary: "Enable Banking: exchange the authorization code",
    description:
      "Session-only. Completes the consent flow: exchanges the code from the bank redirect for a session, persists it into the connector config and restarts the worker.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Authorization code", "application/json",
       %Schema{
         type: :object,
         properties: %{code: %Schema{type: :string}},
         required: [:code]
       }},
    responses: [
      ok:
        {"Connected", "application/json",
         %Schema{
           type: :object,
           properties: %{status: %Schema{type: :string}, accounts: %Schema{type: :integer}}
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Exchange failed", "application/json", Schemas.Error}
    ]
  )

  def eb_exchange(conn, %{"id" => id} = params) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)
    code = params["code"]

    cond do
      config.connector_type != "enable_banking" ->
        unprocessable(conn, "Not an Enable Banking connector")

      not is_binary(code) or code == "" ->
        unprocessable(conn, "code is required")

      true ->
        case EnableBankingConnector.exchange_code(config.config || %{}, code) do
          {:ok, session_fields} ->
            Connectors.persist_connector_cursor(config.id, session_fields)

            # Restart the worker so that it uses the new session.
            Connectors.stop_connector(user_id, config.id)
            if config.enabled, do: Connectors.start_connector(user_id, config.id)

            json(conn, %{status: "connected", accounts: length(session_fields["accounts"])})

          {:error, message} ->
            unprocessable(conn, message)
        end
    end
  end

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  operation(:import_file,
    summary: "Import a file into a connector",
    description:
      "Session-only. Multipart form with a `file` field; only some connector types support file import.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Upload", "multipart/form-data",
       %Schema{
         type: :object,
         properties: %{file: %Schema{type: :string, format: :binary}},
         required: [:file]
       }},
    responses: [
      ok:
        {"Import result", "application/json", %Schema{type: :object, additionalProperties: true}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Import failed", "application/json", Schemas.Error}
    ]
  )

  def import_file(conn, %{"id" => id, "file" => %Plug.Upload{} = upload}) do
    user_id = conn.assigns.current_user.id

    case Connectors.import_file(user_id, id, upload) do
      {:ok, result} ->
        json(conn, Map.put(result, :status, "ok"))

      {:error, :unsupported} ->
        import_error(conn, "This connector does not support file import")

      {:error, {:init_failed, reason}} ->
        import_error(conn, inspect(reason))

      {:error, {:import_failed, reason}} ->
        import_error(conn, to_string(reason))
    end
  end

  def import_file(conn, %{"id" => _id}) do
    import_error(conn, "A file is required")
  end

  defp import_error(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  operation(:logs,
    summary: "List sync logs for a connector",
    description: "Session-only.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Sync logs", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :array,
               items: %Schema{
                 type: :object,
                 properties: %{
                   id: %Schema{type: :string, format: :uuid},
                   status: %Schema{type: :string},
                   entries_count: %Schema{type: :integer, nullable: true},
                   error: %Schema{type: :string, nullable: true},
                   started_at: %Schema{type: :string, format: :"date-time", nullable: true},
                   finished_at: %Schema{type: :string, format: :"date-time", nullable: true}
                 }
               }
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def logs(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    # Make sure that the user owns the config.
    _config = Connectors.get_connector_config!(user_id, id)
    logs = Connectors.list_sync_logs(id)

    json(conn, %{
      data:
        Enum.map(logs, fn log ->
          %{
            id: log.id,
            status: log.status,
            entries_count: log.entries_count,
            error: log.error,
            started_at: log.started_at,
            finished_at: log.finished_at
          }
        end)
    })
  end

  operation(:schedules,
    summary: "List supported schedules for a connector type",
    description: "Session-only.",
    parameters: [connector_type: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Schedules", "application/json",
         %Schema{
           type: :object,
           properties: %{
             schedules: %Schema{type: :array, items: %Schema{type: :string}},
             default: %Schema{type: :string}
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      not_found: {"Unknown connector type", "application/json", Schemas.Error}
    ]
  )

  def schedules(conn, %{"connector_type" => connector_type}) do
    case Map.get(Connectors.connector_modules(), connector_type) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Unknown connector type"})

      module ->
        json(conn, %{
          schedules: module.supported_schedules(),
          default: module.default_schedule()
        })
    end
  end

  defp config_json(config) do
    %{
      id: config.id,
      connector_type: config.connector_type,
      name: config.name,
      enabled: config.enabled,
      config: Connectors.redact_config(config.config),
      schedule: config.schedule,
      last_synced_at: config.last_synced_at,
      error: config.error,
      inserted_at: config.inserted_at,
      updated_at: config.updated_at
    }
  end
end
