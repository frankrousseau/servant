defmodule Servant.Connectors.Worker do
  @moduledoc """
  GenServer that runs a connector on schedule.
  """

  # `:transient` so a clean `{:stop, reason}` from `init/1` (a config error like
  # a missing wallet address) is NOT retried. Under the default `:permanent`
  # restart, such a config would loop until the DynamicSupervisor's max_restarts
  # tripped, taking down every other user's worker with it.
  use GenServer, restart: :transient
  require Logger

  alias Servant.Connectors
  alias Servant.Connectors.ConnectorConfig
  alias Servant.Data
  alias Servant.Repo

  # Never busy-loop the "continuous" schedule (which maps to a 0ms interval):
  # floor it so back-to-back syncs can't peg a core and flood sync_logs.
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
  Triggers an immediate sync regardless of the schedule.
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

    # Re-read the config from the DB rather than trusting the opts captured at
    # start_child time: on a supervisor restart those opts are stale (the
    # persisted cursor — last_block/last_signature/refresh_token — has since
    # advanced), which would re-scan from the start. Fall back to the opts if
    # the row is gone.
    stored = Repo.get(ConnectorConfig, config_id)
    config = (stored && stored.config) || Keyword.get(opts, :config, %{})

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

        Connectors.persist_connector_cursor(
          state.config_id,
          state.connector_module.persisted_config(new_connector_state)
        )

        update_sync_status(state.config_id, nil)
        schedule_sync(%{state | state: new_connector_state})

      {:error, reason, new_connector_state} ->
        Logger.error("Connector sync error: #{inspect(reason)}")
        Connectors.fail_sync_log(sync_log, inspect(reason))
        update_sync_status(state.config_id, inspect(reason))
        schedule_sync(%{state | state: new_connector_state})
    end
  end

  # A DB error while opening the sync log shouldn't crash the worker (which,
  # under the supervisor, would restart it with stale opts). Log, re-arm, move on.
  defp handle_sync_log_error(%__MODULE__{} = state, reason) do
    Logger.error("Connector sync could not start (sync_log): #{inspect(reason)}")
    schedule_sync(state)
  end

  # Schedules the next :sync, cancelling any timer already pending so manual
  # `sync_now` calls (and re-entrant scheduling) can't stack up parallel timer
  # chains. Returns the updated state carrying the new timer ref.
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
