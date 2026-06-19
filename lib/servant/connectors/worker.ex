defmodule Servant.Connectors.Worker do
  @moduledoc """
  GenServer that runs a connector on schedule.
  """

  use GenServer
  require Logger

  alias Servant.Data
  alias Servant.Connectors
  alias Servant.Connectors.ConnectorConfig

  defstruct [:user_id, :connector_module, :state, :config_id, :schedule]

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
    config = Keyword.get(opts, :config, %{})
    config_id = Keyword.fetch!(opts, :config_id)
    schedule = Keyword.get(opts, :schedule, connector_module.default_schedule())

    case connector_module.init(credentials, config) do
      {:ok, connector_state} ->
        state = %__MODULE__{
          user_id: user_id,
          connector_module: connector_module,
          state: connector_state,
          config_id: config_id,
          schedule: schedule
        }

        maybe_schedule_sync(schedule)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast(:sync_now, %__MODULE__{} = state) do
    do_sync(state)
  end

  @impl true
  def handle_info(:sync, %__MODULE__{} = state) do
    do_sync(state)
  end

  defp do_sync(%__MODULE__{} = state) do
    Logger.info("Syncing connector #{state.connector_module.id()} for user #{state.user_id}")

    {:ok, sync_log} = Connectors.create_sync_log(state.config_id)

    case state.connector_module.sync(state.state) do
      {:ok, entries, new_connector_state} ->
        Enum.each(entries, fn entry_attrs ->
          Data.create_entry(state.user_id, entry_attrs)
        end)

        Connectors.complete_sync_log(sync_log, length(entries))
        update_sync_status(state.config_id, nil)
        maybe_schedule_sync(state.schedule)
        {:noreply, %{state | state: new_connector_state}}

      {:error, reason, new_connector_state} ->
        Logger.error("Connector sync error: #{inspect(reason)}")
        Connectors.fail_sync_log(sync_log, inspect(reason))
        update_sync_status(state.config_id, inspect(reason))
        maybe_schedule_sync(state.schedule)
        {:noreply, %{state | state: new_connector_state}}
    end
  end

  defp maybe_schedule_sync("on_demand"), do: :ok

  defp maybe_schedule_sync("continuous") do
    send(self(), :sync)
  end

  defp maybe_schedule_sync(schedule) do
    case ConnectorConfig.schedule_interval_ms(schedule) do
      nil -> :ok
      interval_ms -> Process.send_after(self(), :sync, interval_ms)
    end
  end

  defp update_sync_status(config_id, error) do
    alias Servant.Repo

    case Repo.get(ConnectorConfig, config_id) do
      nil ->
        :ok

      config ->
        config
        |> Ecto.Changeset.change(%{
          last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
          error: error
        })
        |> Repo.update()
    end
  end
end
