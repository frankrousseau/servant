defmodule Servant.Connectors do
  @moduledoc """
  The Connectors context. Manages the connector configs and the lifecycle of
  the workers.
  """

  import Ecto.Query
  require Logger
  alias Servant.Connectors.{ConnectorConfig, ConnectorEnvironment, SyncLog, Worker}
  alias Servant.Repo

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
    "ovh" => Servant.Connectors.OvhConnector,
    "strava" => Servant.Connectors.StravaConnector,
    "github" => Servant.Connectors.GithubConnector,
    "gitlab" => Servant.Connectors.GitlabConnector,
    "enable_banking" => Servant.Connectors.EnableBankingConnector
  }

  # The connector types that accept an uploaded file. Each type maps to the
  # {module, function} that changes the file contents into entries.
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

  @redacted_secret "••••••"
  @sensitive_substrings ~w(password secret token totp apikey api_key private_key
    key credential cookie session auth pin passphrase mnemonic seed_phrase)

  def update_connector_config(user_id, id, attrs) do
    config = get_connector_config!(user_id, id)

    result =
      config
      |> ConnectorConfig.changeset(restore_redacted(attrs, config.config || %{}))
      |> Repo.update()

    # A worker builds its connector state one time, at init. Without a
    # restart, it continues to sync with the old credentials and the old
    # schedule. Restart the worker so that the edit applies immediately
    # (init reads the row from the DB again).
    with {:ok, updated} <- result do
      if updated.config != config.config or updated.schedule != config.schedule do
        restart_if_running(user_id, id)
      end

      {:ok, updated}
    end
  end

  defp restart_if_running(user_id, config_id) do
    case Registry.lookup(Servant.Connectors.Registry, {user_id, config_id}) do
      [{_pid, _}] ->
        stop_connector(user_id, config_id)
        start_connector(user_id, config_id)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Replaces the values of the sensitive config keys (password, secret, token
  and others) with a redaction marker. As a result, secrets never leave the
  API. Use this function before you serialize a connector config to a client.
  """
  def redact_config(config) when is_map(config) do
    Map.new(config, fn {k, v} ->
      if sensitive_key?(k) and is_binary(v) and v != "" do
        {k, @redacted_secret}
      else
        {k, v}
      end
    end)
  end

  def redact_config(other), do: other

  # A client sends back the redaction marker when it returns a redacted
  # config. In that case, keep the stored secret and do not overwrite it.
  defp restore_redacted(attrs, existing) do
    case Map.get(attrs, "config") do
      incoming when is_map(incoming) ->
        merged =
          Map.new(incoming, fn {k, v} ->
            if v == @redacted_secret, do: {k, Map.get(existing, k)}, else: {k, v}
          end)

        Map.put(attrs, "config", merged)

      _ ->
        attrs
    end
  end

  defp sensitive_key?(key) do
    k = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_substrings, &String.contains?(k, &1))
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
      # The init/1 of a worker can return {:stop, reason} (bad config, removed
      # provider). Without this log, the worker dies at boot with no log and
      # no config.error, and an "enabled" connector stays dead silently.
      # :ignore is normal.
      case start_connector(config.user_id, config.id) do
        {:ok, _pid} ->
          :ok

        :ignore ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to start connector config=#{config.id} user=#{config.user_id}: #{inspect(reason)}"
          )
      end
    end)
  end

  def connector_modules, do: @connector_modules

  @doc """
  Merges the cursor that the `persisted_config/1` of a connector returns into
  its stored config, after a successful sync. As a result, the incremental
  cursors (last_block, last_signature, rotated refresh tokens and others)
  survive a restart.

  Does nothing when the cursor is empty.
  """
  def persist_connector_cursor(_config_id, cursor) when map_size(cursor) == 0, do: :ok

  def persist_connector_cursor(config_id, cursor) when is_map(cursor) do
    # The transaction makes the read-merge-write atomic. Without it, a
    # concurrent API edit of the same config between the read and the write
    # is lost.
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.get(ConnectorConfig, config_id) do
          nil ->
            :ok

          config ->
            merged = Map.merge(config.config || %{}, cursor)

            config
            |> ConnectorConfig.changeset(%{config: merged})
            |> Repo.update()
        end
      end)

    result
  end

  # --- Sync Logs ---

  # Run history of a source: the most recent runs stay, and only the most
  # recent of those keep their details (the bulky part).
  @keep_runs 500
  @keep_details 50
  @max_new_entries 20

  @doc "Opens a run (status running) and trims the history of its source."
  def create_sync_log(config_id) do
    result =
      %SyncLog{}
      |> SyncLog.changeset(%{
        connector_config_id: config_id,
        status: "running",
        started_at: DateTime.truncate(DateTime.utc_now(), :second)
      })
      |> Repo.insert()

    with {:ok, _} <- result, do: prune_sync_logs(config_id)
    result
  end

  @doc """
  Closes a run as completed. `summary` holds the counts (`entries_count`,
  the new entries; `fetched_count`; `http_count`, `http_failed_count`,
  `log_count`) and `details` (see `Servant.Connectors.SyncTrace`).
  """
  def complete_sync_log(sync_log, summary) do
    close_sync_log(sync_log, Map.put(summary, :status, "completed"))
  end

  @doc "Closes a run as failed, with its error and the same summary."
  def fail_sync_log(sync_log, error, summary \\ %{}) do
    close_sync_log(sync_log, Map.merge(summary, %{status: "failed", error: to_string(error)}))
  end

  # The details are the bulky, optional part: when they cannot be written
  # (a term JSON cannot encode), the run still records its status and counts.
  defp close_sync_log(sync_log, attrs) do
    attrs = Map.put(attrs, :finished_at, DateTime.truncate(DateTime.utc_now(), :second))

    try do
      sync_log |> SyncLog.changeset(attrs) |> Repo.update()
    rescue
      _ -> sync_log |> SyncLog.changeset(Map.delete(attrs, :details)) |> Repo.update()
    end
  end

  @doc """
  Trims the run history of a source: the #{@keep_runs} most recent runs
  stay, and only the #{@keep_details} most recent keep their details.
  """
  def prune_sync_logs(config_id) do
    runs = where(SyncLog, connector_config_id: ^config_id)

    keep =
      runs
      |> order_by(desc: :started_at, desc: :inserted_at)
      |> limit(@keep_runs)
      |> select([log], log.id)
      |> Repo.all()

    runs |> where([log], log.id not in ^keep) |> Repo.delete_all()

    detailed = Enum.take(keep, @keep_details)

    # nil written in the query, not passed as a value: a nil value goes
    # through the :map type and lands as the JSON text "null", not NULL.
    runs
    |> where([log], log.id not in ^detailed and not is_nil(log.details))
    |> update(set: [details: nil])
    |> Repo.update_all([])

    :ok
  end

  @doc """
  Inserts the entries a run returned and says what they brought:
  `{%{entries_count: new, fetched_count: returned}, %{kinds: ..., new_entries: ...}}`.
  The syncs (`Worker`) and the file imports share it.
  """
  def insert_run_entries(user_id, entries) do
    {:ok, inserted, new_entries} =
      Servant.Data.create_entries_sampled(user_id, entries, @max_new_entries)

    {%{entries_count: inserted, fetched_count: length(entries)},
     %{kinds: Enum.frequencies_by(entries, &entry_kind/1), new_entries: new_entries}}
  end

  defp entry_kind(entry), do: Map.get(entry, "kind") || Map.get(entry, :kind) || "unknown"

  @doc """
  Imports the contents of an uploaded file into the entries of a connector
  that supports file import. Also records a sync log.

  Returns:
    * `{:ok, %{imported: n, total: n, skipped: n}}` on success
    * `{:error, :unsupported}` if the connector type has no importer
    * `{:error, {:init_failed, reason}}` if the connector cannot init
    * `{:error, {:import_failed, reason}}` if the parse of the file fails
  """
  def import_file(user_id, config_id, %Plug.Upload{path: path, filename: filename}) do
    config = get_connector_config!(user_id, config_id)
    workspace = Servant.Storage.tmp_workspace(user_id)
    staged = Path.join(workspace, "import#{Path.extname(filename)}")

    try do
      # The copy is in the try. As a result, a copy that fails (for example on
      # a full disk) still goes through the `after` cleanup and does not leak
      # the tmp workspace.
      File.cp!(path, staged)
      content = staged |> File.read!() |> Servant.Util.strip_bom()

      case Map.get(@importable_types, config.connector_type) do
        nil ->
          {:error, :unsupported}

        {module, import_fn} ->
          case module.init(%{}, config.config || %{}) do
            {:ok, state} ->
              {:ok, sync_log} = create_sync_log(config.id)

              # The importers get the user id in addition to their own state.
              # An importer can change an item embedded in the file (a vCard
              # photo) into a stored file. For that, it must know which user
              # owns the storage.
              import_state = Map.put(state, :user_id, user_id)

              run_import(
                module,
                import_fn,
                content,
                import_state,
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

  defp run_import(
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
       ) do
    case apply(module, import_fn, [content, state]) do
      {:ok, []} ->
        fail_sync_log(sync_log, "No entries found in file")
        {:error, {:import_failed, "No entries found, check file format and connector preset"}}

      {:ok, entries} ->
        {counts, details} = insert_run_entries(user_id, entries)
        complete_sync_log(sync_log, Map.put(counts, :details, details))

        update_connector_config(user_id, config_id, %{
          "last_synced_at" => DateTime.truncate(DateTime.utc_now(), :second),
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
           imported: counts.entries_count,
           total: length(entries),
           skipped: length(entries) - counts.entries_count,
           file_path: Servant.Storage.public_url(relative)
         }}

      {:error, reason} ->
        fail_sync_log(sync_log, reason)
        {:error, {:import_failed, reason}}
    end
  end

  # Everything but the bulky details, which one run's page reads on its own.
  @sync_log_summary SyncLog.__schema__(:fields) -- [:details]

  @doc """
  The most recent runs of a source, newest first, as maps without their
  details: `has_details` says whether `get_sync_log!/2` has some.
  """
  def list_sync_logs(config_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    SyncLog
    |> where(connector_config_id: ^config_id)
    |> order_by(desc: :started_at, desc: :inserted_at)
    |> limit(^limit)
    |> select([log], map(log, ^@sync_log_summary))
    |> select_merge([log], %{has_details: not is_nil(log.details)})
    |> Repo.all()
  end

  @doc "One run of a source, details included. Raises when it is not that source's."
  def get_sync_log!(config_id, log_id) do
    Repo.get_by!(SyncLog, id: log_id, connector_config_id: config_id)
  end

  # --- ConnectorEnvironment (shared reference data cache) ---

  def get_env(connector_type, namespace, key) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

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
    now = DateTime.truncate(DateTime.utc_now(), :second)

    # Atomic upsert on the unique (connector_type, namespace, key) index. A
    # plain get-then-insert has a race when two workers resolve the same new
    # key at the same time: both see nil, and the second insert hits the
    # constraint. insert_all with on_conflict fully prevents the crash.
    Repo.insert_all(
      ConnectorEnvironment,
      [
        %{
          id: Ecto.UUID.generate(),
          connector_type: connector_type,
          namespace: namespace,
          key: key,
          value: value,
          expires_at: expires_at,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:value, :expires_at, :updated_at]},
      conflict_target: [:connector_type, :namespace, :key]
    )

    :ok
  end

  def cleanup_expired_env do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    ConnectorEnvironment
    |> where([e], not is_nil(e.expires_at) and e.expires_at <= ^now)
    |> Repo.delete_all()
  end
end
