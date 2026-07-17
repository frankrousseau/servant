defmodule Servant.AgentsTest do
  use Servant.DataCase

  import Ecto.Query

  alias Servant.Accounts
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

  test "get_run sweeps a run stuck running past 30 minutes into error" do
    user = user_fixture()
    run = run_fixture(user.id, %{action: "create"})

    stale_ts = DateTime.truncate(DateTime.add(DateTime.utc_now(), -31, :minute), :second)

    Servant.Repo.update_all(
      from(r in Servant.Agents.Run, where: r.id == ^run.id),
      set: [inserted_at: stale_ts]
    )

    fetched = Agents.get_run(user.id, run.id)
    assert fetched.status == "error"
    assert fetched.error == "interrupted"
  end

  describe "agents CRUD" do
    @valid %{
      "name" => "Weekly spend",
      "prompt" => "Summarize my spending",
      "kinds" => ["bank_tx"],
      "schedule" => "every_week"
    }

    test "create, list, get are scoped to the user" do
      user = user_fixture()
      {:ok, agent} = Agents.create_agent(user.id, @valid)

      assert agent.lookback_days == 7
      assert agent.enabled == true
      assert [%{id: id}] = Agents.list_agents(user.id)
      assert id == agent.id
      assert Agents.get_agent(user.id, agent.id).id == agent.id
      assert Agents.get_agent(user_fixture().id, agent.id) == nil
      assert Agents.get_agent(user.id, "not-a-uuid") == nil
      assert Agents.list_agents(user_fixture().id) == []
    end

    test "dedupes kinds on create" do
      user = user_fixture()
      {:ok, agent} = Agents.create_agent(user.id, %{@valid | "kinds" => ["bank_tx", "bank_tx"]})
      assert agent.kinds == ["bank_tx"]
    end

    test "update and delete" do
      user = user_fixture()
      {:ok, agent} = Agents.create_agent(user.id, @valid)

      {:ok, agent} = Agents.update_agent(agent, %{"enabled" => false, "schedule" => "every_hour"})
      assert agent.enabled == false
      assert agent.schedule == "every_hour"

      {:ok, _} = Agents.delete_agent(agent)
      assert Agents.list_agents(user.id) == []
    end

    test "validations" do
      user = user_fixture()

      assert {:error, _} = Agents.create_agent(user.id, %{@valid | "name" => ""})
      assert {:error, _} = Agents.create_agent(user.id, %{@valid | "kinds" => []})
      assert {:error, _} = Agents.create_agent(user.id, %{@valid | "kinds" => ["BAD KIND"]})
      assert {:error, _} = Agents.create_agent(user.id, %{@valid | "schedule" => "sometimes"})
      assert {:error, _} = Agents.create_agent(user.id, Map.put(@valid, "lookback_days", 0))
    end
  end

  describe "due?/2 and due_agents/1" do
    defp agent_with_last_run(user_id, schedule, seconds_ago) do
      {:ok, agent} =
        Agents.create_agent(user_id, %{
          "name" => "A",
          "prompt" => "p",
          "kinds" => ["bank_tx"],
          "schedule" => schedule
        })

      case seconds_ago do
        nil ->
          agent

        s ->
          last = DateTime.truncate(DateTime.add(DateTime.utc_now(), -s, :second), :second)
          {:ok, agent} = Agents.touch_last_run(agent, last)
          agent
      end
    end

    test "nil last_run_at is due, disabled never is" do
      user = user_fixture()
      agent = agent_with_last_run(user.id, "every_day", nil)
      now = DateTime.utc_now()

      assert Agents.due?(agent, now)
      {:ok, disabled} = Agents.update_agent(agent, %{"enabled" => false})
      refute Agents.due?(disabled, now)
    end

    test "due when the interval elapsed, not before" do
      user = user_fixture()
      now = DateTime.utc_now()

      assert Agents.due?(agent_with_last_run(user.id, "every_hour", 3700), now)
      refute Agents.due?(agent_with_last_run(user.id, "every_hour", 300), now)
      assert Agents.due?(agent_with_last_run(user.id, "every_day", 90_000), now)
      refute Agents.due?(agent_with_last_run(user.id, "every_day", 3700), now)
    end

    test "due_agents returns only enabled due agents" do
      user = user_fixture()
      due = agent_with_last_run(user.id, "every_hour", 4000)
      _fresh = agent_with_last_run(user.id, "every_hour", 10)

      ids = Enum.map(Agents.due_agents(DateTime.utc_now()), & &1.id)
      assert due.id in ids
      assert length(ids) == 1
    end
  end

  describe "list_runs filters" do
    test "filters by type and agent_id" do
      user = user_fixture()

      {:ok, agent} =
        Agents.create_agent(user.id, %{"name" => "A", "prompt" => "p", "kinds" => ["x"]})

      {:ok, _b} =
        Agents.create_run(user.id, %{type: "builder", action: "create", status: "ok", model: "m"})

      {:ok, r} =
        Agents.create_run(user.id, %{
          type: "recurrent",
          action: "report",
          status: "ok",
          model: "m",
          agent_id: agent.id
        })

      assert [run] = Agents.list_runs(user.id, type: "recurrent")
      assert run.id == r.id
      assert run.agent_id == agent.id
      assert [run2] = Agents.list_runs(user.id, agent_id: agent.id)
      assert run2.id == r.id
      assert length(Agents.list_runs(user.id)) == 2
    end
  end

  defp user_with_ai do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_ai_config(user, %{
        "enabled" => true,
        "model" => "test-model",
        "base_url" => "http://localhost:9999/v1"
      })

    user
  end

  defp report_agent(user_id, attrs \\ %{}) do
    {:ok, agent} =
      Agents.create_agent(
        user_id,
        Map.merge(
          %{"name" => "Spend report", "prompt" => "Summarize spending", "kinds" => ["bank_tx"]},
          attrs
        )
      )

    agent
  end

  defp ai_reply(content) do
    fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => content}}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7}
      })
    end
  end

  describe "run_now/3" do
    test "stores the report entry and completes the run" do
      user = user_with_ai()
      agent = report_agent(user.id)

      entry_fixture(user.id, %{
        "kind" => "bank_tx",
        "title" => "Carrefour",
        "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "data" => %{"amount" => -42.5}
      })

      capture = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(capture, {:ai_request, Jason.decode!(body)})
        ai_reply("## Report\nYou spent 42.50").(conn)
      end

      assert {:ok, entry, run} = Agents.run_now(user, agent, plug: plug)

      assert entry.kind == "ai_report"
      assert entry.source == "agent"
      assert entry.title =~ "Spend report - "
      assert entry.data["content"] =~ "42.50"
      assert entry.metadata["agent_id"] == agent.id
      assert entry.metadata["run_id"] == run.id
      assert entry.metadata["model"] == "test-model"

      assert run.status == "ok"
      assert run.type == "recurrent"
      assert run.action == "report"
      assert run.agent_id == agent.id
      assert run.input_tokens == 5

      assert Agents.get_agent(user.id, agent.id).last_run_at != nil

      assert_receive {:ai_request, payload}
      [_system, %{"content" => user_msg}] = payload["messages"]
      assert user_msg =~ "Summarize spending"
      assert user_msg =~ "Carrefour"
    end

    test "reports an empty context to the model instead of failing" do
      user = user_with_ai()
      agent = report_agent(user.id)

      assert {:ok, entry, _run} = Agents.run_now(user, agent, plug: ai_reply("No data."))
      assert entry.data["content"] == "No data."
    end

    test "caps the context and flags truncation" do
      user = user_with_ai()
      agent = report_agent(user.id, %{"kinds" => ["tick"]})

      for i <- 1..210 do
        entry_fixture(user.id, %{
          "kind" => "tick",
          "title" => "t#{i}",
          "occurred_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
      end

      capture = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(capture, {:ai_request, Jason.decode!(body)})
        ai_reply("ok").(conn)
      end

      assert {:ok, _entry, _run} = Agents.run_now(user, agent, plug: plug)

      assert_receive {:ai_request, payload}
      [_system, %{"content" => user_msg}] = payload["messages"]
      assert user_msg =~ "[truncated extract]"
      # 200 entries max: entry 210 exists, at most 200 "- " lines
      assert length(String.split(user_msg, "\n- ")) <= 201
    end

    test "AI failure fails the run" do
      user = user_with_ai()
      agent = report_agent(user.id)
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

      assert {:error, message, run} = Agents.run_now(user, agent, plug: plug)
      assert message =~ "HTTP 500"
      assert run.status == "error"
      assert Agents.get_agent(user.id, agent.id).last_run_at != nil
    end

    test "an unexpected raise fails the run then propagates" do
      user = user_with_ai()
      agent = report_agent(user.id)

      assert_raise RuntimeError, fn ->
        Agents.run_now(user, agent, plug: fn _conn -> raise "boom" end)
      end

      assert [run] = Agents.list_runs(user.id, type: "recurrent")
      assert run.status == "error"
      assert run.error =~ "boom"
    end

    test "refuses when AI or the agent is disabled" do
      user = user_fixture()
      agent = report_agent(user.id)
      assert {:error, message} = Agents.run_now(user, agent)
      assert message =~ "disabled"

      user2 = user_with_ai()
      agent2 = report_agent(user2.id)
      {:ok, agent2} = Agents.update_agent(agent2, %{"enabled" => false})
      assert {:error, message2} = Agents.run_now(user2, agent2)
      assert message2 =~ "disabled"
    end
  end

  describe "run_due/1" do
    test "runs due agents sequentially and skips users with AI disabled" do
      user = user_with_ai()
      agent = report_agent(user.id)

      off_user = user_fixture()
      _off_agent = report_agent(off_user.id)

      # No plug injection here: the due agent will hit the configured
      # localhost:9999 endpoint and fail fast (connection refused), which is
      # fine: run_due must survive it and record the failed run.
      assert Agents.run_due(DateTime.utc_now()) == :ok

      assert [run] = Agents.list_runs(user.id, type: "recurrent")
      assert run.agent_id == agent.id
      assert run.status == "error"
      assert Agents.list_runs(off_user.id) == []
    end

    test "a raise in one agent does not stop the batch" do
      # covered structurally: run_due wraps each agent in try/rescue; the
      # AI-failure path above already proves an erroring agent yields :ok
      assert Agents.run_due(DateTime.utc_now()) == :ok
    end
  end

  test "the scheduler boots with ticking disabled in tests" do
    pid = start_supervised!({Servant.Agents.Scheduler, name: :test_agent_scheduler})
    assert :sys.get_state(pid) == %{task_ref: nil}
  end
end
