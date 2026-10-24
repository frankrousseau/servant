defmodule Servant.Media.BackfillTest do
  use ExUnit.Case, async: false

  alias Servant.Media.Backfill

  # These tests go through the single-flight guard only (the already-registered
  # branch). As a result, no task reaches the DB, and the spawned task stays
  # clear of the Ecto sandbox.

  test "running? reflects the registry" do
    uid = "u-#{System.unique_integer([:positive])}"
    refute Backfill.running?(uid)

    {:ok, _} = Registry.register(Servant.Media.BackfillRegistry, uid, nil)
    assert Backfill.running?(uid)
  end

  test "a second start no-ops while a job holds the slot" do
    uid = "u-#{System.unique_integer([:positive])}"
    # The test process claims the slot and stands in for an in-flight job.
    {:ok, _owner} = Registry.register(Servant.Media.BackfillRegistry, uid, nil)

    {:ok, pid} = Backfill.start(uid)
    ref = Process.monitor(pid)
    # The reason is :noproc when the task exited before the monitor attached.
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5000
    assert reason in [:normal, :noproc]

    # The spawned task found the slot taken and exited without work. Our claim holds.
    assert Backfill.running?(uid)
  end
end
