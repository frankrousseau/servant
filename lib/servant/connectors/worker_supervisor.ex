defmodule Servant.Connectors.WorkerSupervisor do
  @moduledoc """
  Supervises the connector worker DynamicSupervisor together with the Scheduler,
  using `:rest_for_one` so the two never drift apart.

  The Scheduler starts every enabled connector once, on boot. If the
  DynamicSupervisor were a plain sibling of the Scheduler under the root
  `:one_for_one` tree and its restart intensity were exceeded (several workers
  crashing at once), the root would restart it *empty* and leave the Scheduler
  untouched, so no worker would ever be re-started until a full app restart.
  Ordered `:rest_for_one` (DynamicSupervisor first, Scheduler second) means the
  DynamicSupervisor dying also restarts the Scheduler, which re-runs
  `start_all_enabled/0`.
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
