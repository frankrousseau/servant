defmodule Servant.Connectors do
  @moduledoc """
  The Connectors context. Manages connector configs and worker lifecycle.
  """

  import Ecto.Query
  alias Servant.Repo
  alias Servant.Connectors.{ConnectorConfig, ConnectorEnvironment, SyncLog, Worker}

  @connector_modules %{
    "rss" => Servant.Connectors.RSSConnector,
    "solana" => Servant.Connectors.SolanaConnector,
    "hyperevm" => Servant.Connectors.HyperEVMConnector,
    "arbitrum" => Servant.Connectors.ArbitrumConnector,
    "base" => Servant.Connectors.BaseConnector,
    "ethereum" => Servant.Connectors.EthereumConnector,
    "bank_csv" => Servant.Connectors.BankCSVConnector,
    "ical" => Servant.Connectors.ICalConnector,
    "vcard" => Servant.Connectors.VCardConnector,
    "apple_health" => Servant.Connectors.AppleHealthConnector,
    "invoice_scraper" => Servant.Connectors.InvoiceScraperConnector,
    "strava" => Servant.Connectors.StravaConnector
  }

  # Connector types that accept an uploaded file, mapped to the
  # {module, function} used to turn file contents into entries.
  @importable_types %{
    "bank_csv" => {Servant.Connectors.BankCSVConnector, :import_csv},
    "ical" => {Servant.Connectors.ICalConnector, :import_ical},
    "vcard" => {Servant.Connectors.VCardConnector, :import_vcard},
    "apple_health" => {Servant.Connectors.AppleHealthConnector, :import_health}
  }

  def list_connector_configs(user_id) do
    ConnectorConfig
    |> where(user_id: ^user_id)
    |> Repo.all()
  end

  def get_connector_config!(user_id, id) do
    Repo.get_by!(ConnectorConfig, id: id, user_id: user_id)
  end

  def create_connector_config(user_id, attrs) do
    %ConnectorConfig{user_id: user_id}
    |> ConnectorConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_connector_config(user_id, id, attrs) do
    get_connector_config!(user_id, id)
    |> ConnectorConfig.changeset(attrs)
    |> Repo.update()
  end

  def delete_connector_config(user_id, id) do
    config = get_connector_config!(user_id, id)
    stop_connector(user_id, id)
    Repo.delete(config)
  end

  def start_connector(user_id, config_id) do
    config = get_connector_config!(user_id, config_id)

    case Map.get(@connector_modules, config.connector_type) do
      nil ->
        {:error, :unknown_connector_type}

      module ->
        opts = [
          user_id: user_id,
          connector_module: module,
          config_id: config.id,
          credentials: %{},
          config: config.config || %{},
          schedule: config.schedule || module.default_schedule()
        ]

        DynamicSupervisor.start_child(Servant.Connectors.Supervisor, {Worker, opts})
    end
  end

  def sync_now(user_id, config_id) do
    case Registry.lookup(Servant.Connectors.Registry, {user_id, config_id}) do
      [{_pid, _}] ->
        Worker.sync_now(user_id, config_id)
        :ok

      [] ->
        {:error, :not_running}
    end
  end

  def stop_connector(user_id, config_id) do
    case Registry.lookup(Servant.Connectors.Registry, {user_id, config_id}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Servant.Connectors.Supervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  def start_all_enabled do
    ConnectorConfig
    |> where(enabled: true)
    |> Repo.all()
    |> Enum.each(fn config ->
      start_connector(config.user_id, config.id)
    end)
  end

  def connector_modules, do: @connector_modules

  # --- Sync Logs ---

  def create_sync_log(config_id) do
    %SyncLog{}
    |> SyncLog.changeset(%{
      connector_config_id: config_id,
      status: "running",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  def complete_sync_log(sync_log, entries_count) do
    sync_log
    |> SyncLog.changeset(%{
      status: "completed",
      entries_count: entries_count,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  def fail_sync_log(sync_log, error) do
    sync_log
    |> SyncLog.changeset(%{
      status: "failed",
      error: to_string(error),
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Imports the contents of an uploaded file into the entries of a
  file-import-capable connector, recording a sync log.

  Returns:
    * `{:ok, %{imported: n, total: n, skipped: n}}` on success
    * `{:error, :unsupported}` if the connector type has no importer
    * `{:error, {:init_failed, reason}}` if the connector cannot init
    * `{:error, {:import_failed, reason}}` if parsing the file fails
  """
  def import_file(user_id, config_id, %Plug.Upload{path: path, filename: filename}) do
    config = get_connector_config!(user_id, config_id)
    workspace = Servant.Storage.tmp_workspace(user_id)
    staged = Path.join(workspace, "import#{Path.extname(filename)}")
    File.cp!(path, staged)

    try do
      content = staged |> File.read!() |> strip_bom()

      case Map.get(@importable_types, config.connector_type) do
        nil ->
          {:error, :unsupported}

        {module, import_fn} ->
          case module.init(%{}, config.config || %{}) do
            {:ok, state} ->
              {:ok, sync_log} = create_sync_log(config.id)

              run_import(
                module,
                import_fn,
                content,
                state,
                sync_log,
                user_id,
                config_id,
                config,
                staged,
                filename
              )

            {:error, reason} ->
              {:error, {:init_failed, reason}}
          end
      end
    after
      Servant.Storage.cleanup_tmp(workspace)
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp run_import(module, import_fn, content, state, sync_log, user_id, config_id, config, staged, filename) do
    case apply(module, import_fn, [content, state]) do
      {:ok, []} ->
        fail_sync_log(sync_log, "No entries found in file")
        {:error, {:import_failed, "No entries found — check file format and connector preset"}}

      {:ok, entries} ->
        inserted =
          Enum.count(entries, fn attrs ->
            match?({:ok, _}, Servant.Data.create_entry(user_id, attrs))
          end)

        complete_sync_log(sync_log, inserted)

        update_connector_config(user_id, config_id, %{
          "last_synced_at" => DateTime.utc_now() |> DateTime.truncate(:second),
          "error" => nil
        })

        {:ok, relative, _absolute} =
          Servant.Storage.store_connector_file(
            user_id,
            config.connector_type,
            config.id,
            staged,
            filename
          )

        {:ok,
         %{
           imported: inserted,
           total: length(entries),
           skipped: length(entries) - inserted,
           file_path: Servant.Storage.public_url(relative)
         }}

      {:error, reason} ->
        fail_sync_log(sync_log, reason)
        {:error, {:import_failed, reason}}
    end
  end

  def list_sync_logs(config_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SyncLog
    |> where(connector_config_id: ^config_id)
    |> order_by(desc: :started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- ConnectorEnvironment (shared reference data cache) ---

  def get_env(connector_type, namespace, key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ConnectorEnvironment
    |> where(connector_type: ^connector_type, namespace: ^namespace, key: ^key)
    |> where([e], is_nil(e.expires_at) or e.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> nil
      env -> env.value
    end
  end

  def put_env(connector_type, namespace, key, value, expires_at \\ nil) do
    expires_at = if expires_at, do: DateTime.truncate(expires_at, :second)

    case Repo.get_by(ConnectorEnvironment,
           connector_type: connector_type,
           namespace: namespace,
           key: key
         ) do
      nil ->
        %ConnectorEnvironment{}
        |> ConnectorEnvironment.changeset(%{
          connector_type: connector_type,
          namespace: namespace,
          key: key,
          value: value,
          expires_at: expires_at
        })
        |> Repo.insert()

      existing ->
        existing
        |> ConnectorEnvironment.changeset(%{value: value, expires_at: expires_at})
        |> Repo.update()
    end
  end

  def cleanup_expired_env do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ConnectorEnvironment
    |> where([e], not is_nil(e.expires_at) and e.expires_at <= ^now)
    |> Repo.delete_all()
  end
end
