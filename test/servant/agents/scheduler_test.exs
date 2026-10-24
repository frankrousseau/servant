defmodule Servant.Agents.SchedulerTest do
  use Servant.DataCase

  alias Servant.Agents.Scheduler

  test "does not tick on its own in tests" do
    pid = start_supervised!({Scheduler, name: :test_agents_scheduler})
    assert :sys.get_state(pid) == %{task_ref: nil}
  end

  test "a tick runs one batch of due agents and remembers it" do
    assert {:noreply, %{task_ref: ref}} = Scheduler.handle_info(:tick, %{task_ref: nil})
    assert is_reference(ref)

    # The batch runs in the Agents task supervisor and answers the caller.
    assert_receive {^ref, :ok}
  end

  # The local models are slow. A second batch must not join a batch that
  # still runs, or two runs of the same agent overlap.
  test "a tick while a batch runs is skipped" do
    running = make_ref()

    assert {:noreply, %{task_ref: ^running}} =
             Scheduler.handle_info(:tick, %{task_ref: running})

    refute_received {_ref, :ok}
  end

  test "the scheduler is ready again once the batch answers" do
    ref = make_ref()
    assert {:noreply, %{task_ref: nil}} = Scheduler.handle_info({ref, :ok}, %{task_ref: ref})
  end

  test "a crashed batch does not wedge the scheduler" do
    ref = make_ref()

    assert {:noreply, %{task_ref: nil}} =
             Scheduler.handle_info({:DOWN, ref, :process, self(), :boom}, %{task_ref: ref})
  end

  test "unrelated messages are ignored" do
    state = %{task_ref: nil}
    assert {:noreply, ^state} = Scheduler.handle_info(:something_else, state)
  end
end
