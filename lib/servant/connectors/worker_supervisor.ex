defmodule Servant.Connectors.WorkerSupervisor do
  @moduledoc """
  Supervises the DynamicSupervisor of the connector workers together with the
  Scheduler. Uses `:rest_for_one` so that the two never drift apart.

  The Scheduler starts every enabled connector once, on boot. Assume that the
  DynamicSupervisor is a plain sibling of the Scheduler under the root
  `:one_for_one` tree. If several workers crash at the same time and exceed its
  restart intensity, the root restarts it *empty* and does not touch the
  Scheduler. Then no worker starts again until a full restart of the app. With
  the ordered `:rest_for_one` (DynamicSupervisor first, Scheduler second), the
  death of the DynamicSupervisor also restarts the Scheduler. The Scheduler
  then runs `start_all_enabled/0` again.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Servant.Connectors.Supervisor, strategy: :one_for_one},
      Servant.Connectors.Scheduler
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
