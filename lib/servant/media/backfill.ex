defmodule Servant.Media.Backfill do
  @moduledoc """
  Runs the photo-preview backfill under a `Task.Supervisor`, at most one job
  per user at a time. Without this, any authenticated user could fire
  `POST /api/entries/backfill_media` repeatedly and pile up concurrent
  full-library reprocessing jobs, starving CPU/memory shared across tenants.

  Single-flight is a `Registry` unique key per user id, claimed inside the
  task and auto-released when it ends; a second request while one runs spawns
  a task that finds the key taken and exits without doing the work.
  """
  @supervisor Servant.Media.BackfillSupervisor
  @registry Servant.Media.BackfillRegistry

  @doc "Child specs for the app supervision tree."
  def child_specs do
    [
      {Task.Supervisor, name: @supervisor},
      {Registry, keys: :unique, name: @registry}
    ]
  end

  @doc "Starts a backfill for the user unless one is already in flight."
  def start(user_id) do
    Task.Supervisor.start_child(@supervisor, fn -> run(user_id) end)
  end

  @doc "Whether a backfill is currently running for the user."
  def running?(user_id), do: Registry.lookup(@registry, user_id) != []

  defp run(user_id) do
    case Registry.register(@registry, user_id, nil) do
      {:ok, _} -> Servant.Media.Thumbnail.backfill_missing(user_id)
      {:error, {:already_registered, _}} -> :ok
    end
  end
end
