defmodule Servant.Media.BackfillTest do
  use ExUnit.Case, async: false

  alias Servant.Media.Backfill

  # These exercise the single-flight guard only (the already-registered
  # branch), so no task ever reaches the DB — keeps the spawned task clear of
  # the Ecto sandbox.

  test "running? reflects the registry" do
    uid = "u-#{System.unique_integer([:positive])}"
    refute Backfill.running?(uid)

    {:ok, _} = Registry.register(Servant.Media.BackfillRegistry, uid, nil)
    assert Backfill.running?(uid)
  end

  test "a second start no-ops while a job holds the slot" do
    uid = "u-#{System.unique_integer([:positive])}"
    # The test process claims the slot, standing in for an in-flight job.
    {:ok, _owner} = Registry.register(Servant.Media.BackfillRegistry, uid, nil)

    {:ok, pid} = Backfill.start(uid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000

    # The spawned task found the slot taken and exited without work; ours holds.
    assert Backfill.running?(uid)
  end
end
