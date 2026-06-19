defmodule ServantWeb.ConnectorController do
  use ServantWeb, :controller

  alias Servant.Connectors

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    configs = Connectors.list_connector_configs(user_id)
    json(conn, %{data: Enum.map(configs, &config_json/1)})
  end

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)
    json(conn, %{data: config_json(config)})
  end

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

  def stop(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    Connectors.stop_connector(user_id, id)
    json(conn, %{status: "stopped"})
  end

  def import_file(conn, %{"id" => id, "file" => %Plug.Upload{path: path}}) do
    user_id = conn.assigns.current_user.id

    case Connectors.import_file(user_id, id, File.read!(path)) do
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

  def logs(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    # Verify ownership
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
      config: config.config,
      schedule: config.schedule,
      last_synced_at: config.last_synced_at,
      error: config.error,
      inserted_at: config.inserted_at,
      updated_at: config.updated_at
    }
  end
end
