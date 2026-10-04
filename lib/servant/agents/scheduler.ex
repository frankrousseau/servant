defmodule Servant.Agents.Scheduler do
  @moduledoc """
  Ticks every minute and runs the due recurring agents (Servant.Agents.run_due/0)
  in a supervised Task. Only one batch runs at a time. If the previous batch
  still runs (local models are slow), the scheduler skips the tick. The tests
  disable the ticks through config :servant, Servant.Agents.Scheduler, tick: false.
  """

  use GenServer

  alias Servant.Agents

  @tick_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    if tick_enabled?(), do: schedule_tick()
    {:ok, %{task_ref: nil}}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Servant.Agents.TaskSupervisor, &Agents.run_due/0)

    schedule_tick()
    {:noreply, %{state | task_ref: ref}}
  end

  def handle_info(:tick, state) do
    # The previous batch still runs: skip this tick.
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp tick_enabled? do
    :servant
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:tick, true)
  end
end
