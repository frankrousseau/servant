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

  @importable_types %{
    "bank_csv" => {Servant.Connectors.BankCSVConnector, :import_csv},
    "ical" => {Servant.Connectors.ICalConnector, :import_ical},
    "vcard" => {Servant.Connectors.VCardConnector, :import_vcard},
    "apple_health" => {Servant.Connectors.AppleHealthConnector, :import_health}
  }

  def import_file(conn, %{"id" => id, "file" => %Plug.Upload{path: path}}) do
    user_id = conn.assigns.current_user.id
    config = Connectors.get_connector_config!(user_id, id)

    case Map.get(@importable_types, config.connector_type) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "This connector does not support file import"})

      {module, import_fn} ->
        content = File.read!(path)

        case module.init(%{}, config.config || %{}) do
          {:ok, state} ->
            {:ok, sync_log} = Connectors.create_sync_log(config.id)

            case apply(module, import_fn, [content, state]) do
              {:ok, entries} ->
                inserted =
                  Enum.count(entries, fn entry_attrs ->
                    case Servant.Data.create_entry(user_id, entry_attrs) do
                      {:ok, _} -> true
                      {:error, _} -> false
                    end
                  end)

                Connectors.complete_sync_log(sync_log, inserted)

                Connectors.update_connector_config(user_id, id, %{
                  "last_synced_at" => DateTime.utc_now() |> DateTime.truncate(:second),
                  "error" => nil
                })

                json(conn, %{
                  status: "ok",
                  imported: inserted,
                  total: length(entries),
                  skipped: length(entries) - inserted
                })

              {:error, reason} ->
                Connectors.fail_sync_log(sync_log, reason)
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: to_string(reason)})
            end

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end
    end
  end

  def import_file(conn, %{"id" => _id}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "A file is required"})
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

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
