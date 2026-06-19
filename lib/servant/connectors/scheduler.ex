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
    Process.send_after(self(), :start_connectors, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:start_connectors, state) do
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
