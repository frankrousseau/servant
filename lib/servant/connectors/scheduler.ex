defmodule Servant.Connectors.Scheduler do
  @moduledoc """
  On startup, loads all the enabled connector configs and starts the workers.
  """

  use GenServer
  require Logger

  alias Servant.Connectors

  # Sweep the expired shared-env rows once a day, so the table does not grow forever.
  @cleanup_interval_ms :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    # Repo and the Ecto.Migrator run before the Scheduler in the supervision
    # tree, so `handle_continue` is safe here. A hardcoded delay is not necessary.
    {:ok, %{}, {:continue, :start_connectors}}
  end

  @impl true
  def handle_continue(:start_connectors, state) do
    Logger.info("Scheduler: starting enabled connectors")

    try do
      Connectors.start_all_enabled()
    rescue
      e ->
        Logger.error("Scheduler: failed to start connectors: #{inspect(e)}")
    end

    schedule_env_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_env, state) do
    Connectors.cleanup_expired_env()
    schedule_env_cleanup()
    {:noreply, state}
  end

  defp schedule_env_cleanup do
    Process.send_after(self(), :cleanup_env, @cleanup_interval_ms)
  end
end
