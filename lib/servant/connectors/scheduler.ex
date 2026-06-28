defmodule Servant.Connectors.Scheduler do
  @moduledoc """
  On startup, loads all enabled connector configs and starts workers.
  """

  use GenServer
  require Logger

  alias Servant.Connectors

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Repo and the Ecto.Migrator run before the Scheduler in the supervision
    # tree, so `handle_continue` is safe here — no need for a hardcoded delay.
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

    {:noreply, state}
  end
end
