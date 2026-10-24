defmodule Servant.Connectors.Worker do
  @moduledoc """
  GenServer that runs a connector on schedule.
  """

  # `:transient` makes sure that the supervisor does NOT retry a clean
  # `{:stop, reason}` from `init/1` (a config error such as a missing wallet
  # address). With the default `:permanent` restart, such a config loops until
  # it trips the max_restarts of the DynamicSupervisor. That also stops the
  # worker of every other user.
  use GenServer, restart: :transient
  require Logger

  alias Servant.Connectors
  alias Servant.Connectors.ConnectorConfig
  alias Servant.Data
  alias Servant.Repo

  # Never busy-loop the "continuous" schedule (which maps to a 0ms interval).
  # Apply a floor so that back-to-back syncs cannot peg a core and flood sync_logs.
  @continuous_floor_ms 5_000

  defstruct [:user_id, :connector_module, :state, :config_id, :schedule, :timer_ref]

  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    config_id = Keyword.fetch!(opts, :config_id)

    name = via_tuple(user_id, config_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def via_tuple(user_id, config_id) do
    {:via, Registry, {Servant.Connectors.Registry, {user_id, config_id}}}
  end

  @doc """
  Triggers an immediate sync and ignores the schedule.
  """
  def sync_now(user_id, config_id) do
    GenServer.cast(via_tuple(user_id, config_id), :sync_now)
  end

  @impl true
  def init(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    connector_module = Keyword.fetch!(opts, :connector_module)
    credentials = Keyword.get(opts, :credentials, %{})
    config_id = Keyword.fetch!(opts, :config_id)

    # Read the config again from the DB. Do not trust the opts captured at
    # start_child time. On a supervisor restart, those opts are stale: the
    # persisted cursor (last_block/last_signature/refresh_token) moved forward
    # after that time. Stale opts cause a new scan from the start. Use the opts
    # as the fallback if the row is gone.
    stored = Repo.get(ConnectorConfig, config_id)

    # The config also contains the owner. A connector that stores files (OVH
    # invoice PDFs) must have it to scope the blobs and the entry lookups. The
    # owner is never persisted back (persist_connector_cursor only writes
    # persisted_config).
    config = (stored && stored.config) || Keyword.get(opts, :config, %{})
    config = Map.put(config, "user_id", user_id)

    schedule =
      (stored && stored.schedule) || Keyword.get(opts, :schedule) ||
        connector_module.default_schedule()

    case connector_module.init(credentials, config) do
      {:ok, connector_state} ->
        state = %__MODULE__{
          user_id: user_id,
          connector_module: connector_module,
          state: connector_state,
          config_id: config_id,
          schedule: schedule
        }

        {:ok, schedule_sync(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast(:sync_now, %__MODULE__{} = state) do
    {:noreply, do_sync(state)}
  end

  @impl true
  def handle_info(:sync, %__MODULE__{} = state) do
    {:noreply, do_sync(state)}
  end

  defp do_sync(%__MODULE__{} = state) do
    Logger.info("Syncing connector #{state.connector_module.id()} for user #{state.user_id}")

    case Connectors.create_sync_log(state.config_id) do
      {:ok, sync_log} -> run_sync(state, sync_log)
      {:error, reason} -> handle_sync_log_error(state, reason)
    end
  end

  defp run_sync(%__MODULE__{} = state, sync_log) do
    case state.connector_module.sync(state.state) do
      {:ok, entries, new_connector_state} ->
        {:ok, inserted} = Data.create_entries(state.user_id, entries)

        Connectors.complete_sync_log(sync_log, inserted)
        persist_cursor(state, new_connector_state)
        update_sync_status(state.config_id, nil)
        schedule_sync(%{state | state: new_connector_state})

      {:error, reason, new_connector_state} ->
        message = format_reason(reason)
        Logger.error("Connector sync error [#{sync_context(state)}]: #{message}")
        Connectors.fail_sync_log(sync_log, message)
        # Persist the returned state too. A connector possibly rotated a
        # refresh_token before the step that failed. The loss of that token
        # (until the next successful sync) breaks the connector on the next
        # restart.
        persist_cursor(state, new_connector_state)
        update_sync_status(state.config_id, message)
        schedule_sync(%{state | state: new_connector_state})
    end
  rescue
    # Without this rescue, a raise in sync/1 or create_entries crashes the worker
    # and this sync_log stays in "running" forever. Fail the sync_log. Arm the
    # timer again. Continue.
    e ->
      reason = Exception.message(e)
      Logger.error("Connector sync crashed [#{sync_context(state)}]: #{reason}")
      Connectors.fail_sync_log(sync_log, reason)
      update_sync_status(state.config_id, reason)
      schedule_sync(state)
  end

  defp persist_cursor(%__MODULE__{} = state, connector_state) do
    Connectors.persist_connector_cursor(
      state.config_id,
      state.connector_module.persisted_config(connector_state)
    )
  end

  # When a connector made the effort to write a sentence, show it as a sentence.
  # inspect/1 gives the UI an escaped, quoted blob.
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp sync_context(%__MODULE__{} = state) do
    "#{state.connector_module.id()} config=#{state.config_id} user=#{state.user_id}"
  end

  # A DB error at the open of the sync log must not crash the worker. After a
  # crash, the supervisor restarts the worker with stale opts. Log the error.
  # Arm the timer again. Continue.
  defp handle_sync_log_error(%__MODULE__{} = state, reason) do
    Logger.error("Connector sync could not start (sync_log): #{inspect(reason)}")
    schedule_sync(state)
  end

  # Schedules the next :sync. Cancels any timer that is already pending, so
  # manual `sync_now` calls (and re-entrant scheduling) cannot stack up parallel
  # timer chains. Returns the updated state with the new timer ref.
  defp schedule_sync(%__MODULE__{timer_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    %{state | timer_ref: arm_timer(state.schedule)}
  end

  defp arm_timer("on_demand"), do: nil

  defp arm_timer("continuous"),
    do: Process.send_after(self(), :sync, @continuous_floor_ms)

  defp arm_timer(schedule) do
    case ConnectorConfig.schedule_interval_ms(schedule) do
      nil -> nil
      0 -> Process.send_after(self(), :sync, @continuous_floor_ms)
      interval_ms -> Process.send_after(self(), :sync, interval_ms)
    end
  end

  defp update_sync_status(config_id, error) do
    case Repo.get(ConnectorConfig, config_id) do
      nil ->
        :ok

      config ->
        config
        |> Ecto.Changeset.change(%{
          last_synced_at: DateTime.truncate(DateTime.utc_now(), :second),
          error: error
        })
        |> Repo.update()
    end
  end
end
