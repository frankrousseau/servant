defmodule Servant.Agents.Scheduler do
  @moduledoc """
  Ticks every minute and runs due recurring agents (Servant.Agents.run_due/0)
  in a supervised Task. One batch at a time: if the previous batch is still
  running (local models are slow), the tick is skipped. Ticking is disabled
  in tests via config :servant, Servant.Agents.Scheduler, tick: false.
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
    # Previous batch still running: skip this tick.
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
