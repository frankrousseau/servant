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

    case Repo.get_by(ConnectorEnvironment, connector_type: connector_type, namespace: namespace, key: key) do
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
