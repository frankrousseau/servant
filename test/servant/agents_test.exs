defmodule Servant.AgentsTest do
  use Servant.DataCase

  import Ecto.Query

  alias Servant.Agents

  defp run_fixture(user_id, attrs \\ %{}) do
    {:ok, run} =
      Agents.create_run(
        user_id,
        Map.merge(
          %{type: "builder", action: "create", status: "running", model: "m", prompt: "p"},
          attrs
        )
      )

    run
  end

  test "create_run starts a running run scoped to the user" do
    user = user_fixture()
    run = run_fixture(user.id, %{app_id: "todo"})

    assert run.status == "running"
    assert Agents.get_run(user.id, run.id).id == run.id
    assert Agents.get_run(user_fixture().id, run.id) == nil
    assert Agents.get_run(user.id, "not-a-uuid") == nil
  end

  test "complete_run records usage and duration" do
    user = user_fixture()
    run = run_fixture(user.id)

    {:ok, run} = Agents.complete_run(run, %{input_tokens: 10, output_tokens: 20}, 1234)

    assert run.status == "ok"
    assert run.input_tokens == 10
    assert run.output_tokens == 20
    assert run.duration_ms == 1234
  end

  test "complete_run accepts a nil usage" do
    user = user_fixture()
    {:ok, run} = Agents.complete_run(run_fixture(user.id), nil, 5)
    assert run.status == "ok"
    assert run.input_tokens == nil
  end

  test "fail_run records and truncates the error" do
    user = user_fixture()
    {:ok, run} = Agents.fail_run(run_fixture(user.id), String.duplicate("x", 3000))
    assert run.status == "error"
    assert String.length(run.error) == 2000
  end

  test "list_runs returns the user's runs, newest first" do
    user = user_fixture()
    old = run_fixture(user.id, %{action: "create"})
    new = run_fixture(user.id, %{action: "modify"})
    _other = run_fixture(user_fixture().id)

    old_ts = DateTime.truncate(DateTime.add(DateTime.utc_now(), -60, :second), :second)

    Servant.Repo.update_all(
      from(r in Servant.Agents.Run, where: r.id == ^old.id),
      set: [inserted_at: old_ts]
    )

    runs = Agents.list_runs(user.id)
    assert length(runs) == 2
    assert hd(runs).id == new.id
  end

  test "list_runs sweeps runs stuck running past 30 minutes into error, not fresh ones" do
    user = user_fixture()
    stale = run_fixture(user.id, %{action: "create"})
    fresh = run_fixture(user.id, %{action: "modify"})

    stale_ts = DateTime.truncate(DateTime.add(DateTime.utc_now(), -31, :minute), :second)

    Servant.Repo.update_all(
      from(r in Servant.Agents.Run, where: r.id == ^stale.id),
      set: [inserted_at: stale_ts]
    )

    runs = Agents.list_runs(user.id)
    swept = Enum.find(runs, &(&1.id == stale.id))
    untouched = Enum.find(runs, &(&1.id == fresh.id))

    assert swept.status == "error"
    assert swept.error == "interrupted"
    assert untouched.status == "running"
  end
end
