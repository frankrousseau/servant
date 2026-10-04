defmodule Servant.Media.Backfill do
  @moduledoc """
  Runs the photo-preview backfill under a `Task.Supervisor`, with at most one
  job per user at a time. Without this limit, an authenticated user can send
  `POST /api/entries/backfill_media` again and again. The concurrent jobs then
  pile up. Each job processes the full library again. Together, the jobs starve
  the CPU and the memory that the tenants share.

  The single-flight mechanism is a unique `Registry` key per user id. The task
  claims the key, and the `Registry` releases it automatically when the task
  stops. A second request while a job runs spawns a task. This task finds that
  the key is taken and exits. It does not do the work.
  """
  @supervisor Servant.Media.BackfillSupervisor
  @registry Servant.Media.BackfillRegistry

  @doc "Returns the child specs for the supervision tree of the app."
  def child_specs do
    [
      {Task.Supervisor, name: @supervisor},
      {Registry, keys: :unique, name: @registry}
    ]
  end

  @doc """
  Starts a backfill task for the user. The task stops immediately if a
  backfill already runs for this user.
  """
  def start(user_id) do
    Task.Supervisor.start_child(@supervisor, fn -> run(user_id) end)
  end

  @doc "Returns true if a backfill runs for the user at this time."
  def running?(user_id), do: Registry.lookup(@registry, user_id) != []

  defp run(user_id) do
    case Registry.register(@registry, user_id, nil) do
      {:ok, _} -> Servant.Media.Thumbnail.backfill_missing(user_id)
      {:error, {:already_registered, _}} -> :ok
    end
  end
end
