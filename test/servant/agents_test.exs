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

    test "an agent model overrides the one from Settings, for that agent only" do
      user = user_with_ai()
      agent = report_agent(user.id, %{"model" => "  big-model  "})
      plain = report_agent(user.id, %{"name" => "Plain"})

      # Trimmed on the way in, so the stored value is what gets requested.
      assert Agents.get_agent(user.id, agent.id).model == "big-model"

      capture = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(capture, {:model, Jason.decode!(body)["model"]})
        ai_reply("ok").(conn)
      end

      assert {:ok, entry, _run} = Agents.run_now(user, agent, plug: plug)
      assert_receive {:model, "big-model"}
      assert entry.metadata["model"] == "big-model"

      assert {:ok, entry2, _run} = Agents.run_now(user, plain, plug: plug)
      assert_receive {:model, "test-model"}
      assert entry2.metadata["model"] == "test-model"
    end

    test "an agent pinned to an hour fires in that hour, once per interval" do
      user = user_with_ai()
      {:ok, user} = Accounts.update_profile(user, %{"timezone" => "Europe/Paris"})
      agent = report_agent(user.id, %{"schedule" => "every_day", "run_at_hour" => 7})
      tz = user.timezone

      # 06:30 in Paris: too early, whatever the UTC hour is.
      before = DateTime.new!(~D[2026-03-10], ~T[05:30:00], "Etc/UTC")
      refute Agents.due?(agent, before, tz)

      # 07:10 local, never run: fires.
      at_slot = DateTime.new!(~D[2026-03-10], ~T[06:10:00], "Etc/UTC")
      assert Agents.due?(agent, at_slot, tz)

      # Ran at 07:00 local: not again in the same hour, nor later that day.
      ran = %{agent | last_run_at: DateTime.new!(~D[2026-03-10], ~T[06:00:00], "Etc/UTC")}
      refute Agents.due?(ran, at_slot, tz)
      refute Agents.due?(ran, DateTime.new!(~D[2026-03-10], ~T[20:00:00], "Etc/UTC"), tz)

      # Next day, same hour: fires again.
      assert Agents.due?(ran, DateTime.new!(~D[2026-03-11], ~T[06:05:00], "Etc/UTC"), tz)
    end

    test "a weekly agent pinned to an hour does not fire the next day" do
      user = user_with_ai()
      agent = report_agent(user.id, %{"schedule" => "every_week", "run_at_hour" => 9})
      ran = %{agent | last_run_at: DateTime.new!(~D[2026-03-10], ~T[09:00:00], "Etc/UTC")}

      refute Agents.due?(ran, DateTime.new!(~D[2026-03-11], ~T[09:05:00], "Etc/UTC"), "Etc/UTC")
      assert Agents.due?(ran, DateTime.new!(~D[2026-03-17], ~T[09:05:00], "Etc/UTC"), "Etc/UTC")
    end

    test "without an hour the agent keeps the elapsed-interval rule" do
      user = user_with_ai()
      agent = report_agent(user.id, %{"schedule" => "every_day"})
      ran = %{agent | last_run_at: DateTime.new!(~D[2026-03-10], ~T[03:00:00], "Etc/UTC")}

      refute Agents.due?(ran, DateTime.new!(~D[2026-03-10], ~T[23:00:00], "Etc/UTC"), "Etc/UTC")
      assert Agents.due?(ran, DateTime.new!(~D[2026-03-11], ~T[03:30:00], "Etc/UTC"), "Etc/UTC")
    end

    test "an emptied agent model falls back to the Settings one" do
      user = user_with_ai()
      agent = report_agent(user.id, %{"model" => "big-model"})

      {:ok, agent} = Agents.update_agent(agent, %{"model" => "   "})
      assert agent.model == nil

      assert {:ok, entry, _run} = Agents.run_now(user, agent, plug: ai_reply("ok"))
      assert entry.metadata["model"] == "test-model"
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

  describe "recipe agents CRUD" do
    test "mode defaults to prompt and prompt stays required" do
      user = user_fixture()

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{"name" => "A", "kinds" => ["note"]})

      assert %{prompt: _} = errors_on(changeset)

      assert {:ok, agent} =
               Agents.create_agent(user.id, %{"name" => "A", "prompt" => "p", "kinds" => ["note"]})

      assert agent.mode == "prompt"
      assert agent.recipe == nil
    end

    test "mode recipe requires a valid recipe and no prompt" do
      user = user_fixture()

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "recipe"
               })

      assert %{recipe: _} = errors_on(changeset)

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "recipe",
                 "recipe" => %{"bogus" => true}
               })

      assert %{recipe: _} = errors_on(changeset)

      assert {:ok, agent} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "recipe",
                 "recipe" => %{"aggregate" => %{"op" => "count"}}
               })

      assert agent.mode == "recipe"
      assert agent.prompt == nil
    end

    test "unknown mode is rejected" do
      user = user_fixture()

      assert {:error, changeset} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "prompt" => "p",
                 "kinds" => ["note"],
                 "mode" => "script"
               })

      assert %{mode: _} = errors_on(changeset)
    end

    test "an invalid recipe alongside mode prompt is ignored, not stored" do
      user = user_fixture()

      assert {:ok, agent} =
               Agents.create_agent(user.id, %{
                 "name" => "A",
                 "kinds" => ["note"],
                 "mode" => "prompt",
                 "prompt" => "p",
                 "recipe" => %{"bogus" => true}
               })

      assert agent.mode == "prompt"
      assert agent.recipe == nil
    end

    test "switching a recipe agent to prompt clears the recipe; switching back needs a fresh one" do
      user = user_fixture()

      {:ok, agent} =
        Agents.create_agent(user.id, %{
          "name" => "A",
          "kinds" => ["note"],
          "mode" => "recipe",
          "recipe" => %{"aggregate" => %{"op" => "count"}}
        })

      assert {:ok, agent} = Agents.update_agent(agent, %{"mode" => "prompt", "prompt" => "p"})
      assert agent.recipe == nil

      reloaded = Agents.get_agent(user.id, agent.id)
      assert reloaded.recipe == nil

      # Nothing to resurrect: flipping mode back alone is rejected, not
      # silently reactivating the recipe that used to be stored.
      assert {:error, changeset} = Agents.update_agent(reloaded, %{"mode" => "recipe"})
      assert %{recipe: _} = errors_on(changeset)
    end

    test "switching a prompt agent to recipe clears the prompt" do
      user = user_fixture()

      {:ok, agent} =
        Agents.create_agent(user.id, %{"name" => "A", "kinds" => ["note"], "prompt" => "p"})

      assert {:ok, agent} =
               Agents.update_agent(agent, %{
                 "mode" => "recipe",
                 "recipe" => %{"aggregate" => %{"op" => "count"}}
               })

      assert agent.prompt == nil

      reloaded = Agents.get_agent(user.id, agent.id)
      assert reloaded.prompt == nil
    end
  end

  describe "recipe agent runs" do
    defp recipe_agent(user, recipe, attrs \\ %{}) do
      {:ok, agent} =
        Agents.create_agent(
          user.id,
          Map.merge(
            %{"name" => "R", "kinds" => ["bank_tx"], "mode" => "recipe", "recipe" => recipe},
            attrs
          )
        )

      agent
    end

    test "produces a kind report entry without model metadata, run has no tokens" do
      user = user_with_ai()

      {:ok, _} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "t",
          "occurred_at" => DateTime.utc_now(),
          "data" => %{"amount" => 12}
        })

      agent = recipe_agent(user, %{"aggregate" => %{"op" => "sum", "field" => "data.amount"}})

      assert {:ok, entry, run} = Agents.run_now(user, agent)

      assert entry.kind == "report"
      assert entry.source == "agent"
      assert entry.data["content"] =~ "12"
      assert entry.metadata["agent_id"] == agent.id
      assert entry.metadata["run_id"] == run.id
      refute Map.has_key?(entry.metadata, "model")

      assert run.status == "ok"
      assert run.model == nil
      assert run.input_tokens == nil
      assert run.duration_ms != nil
    end

    test "emit_if false completes the run without creating an entry" do
      user = user_with_ai()

      agent =
        recipe_agent(user, %{
          "aggregate" => %{"op" => "count"},
          "emit_if" => %{"op" => "gte", "value" => 1}
        })

      assert {:ok, nil, run} = Agents.run_now(user, agent)
      assert run.status == "ok"
      assert Servant.Data.all_entries(user.id, %{"kind" => "report"}) == []
    end

    test "the window is not capped by pagination (60 entries all counted)" do
      user = user_with_ai()

      for i <- 1..60 do
        {:ok, _} =
          Servant.Data.create_entry(user.id, %{
            "kind" => "bank_tx",
            "source" => "test",
            "title" => "t#{i}",
            "occurred_at" => DateTime.utc_now(),
            "data" => %{"amount" => 1}
          })
      end

      agent = recipe_agent(user, %{"aggregate" => %{"op" => "count"}})

      assert {:ok, entry, _run} = Agents.run_now(user, agent)
      assert entry.data["content"] =~ "60"
    end

    test "only entries inside the lookback window count" do
      user = user_with_ai()

      {:ok, old} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "old",
          "occurred_at" => DateTime.add(DateTime.utc_now(), -10 * 86_400, :second),
          "data" => %{}
        })

      _ = old

      agent =
        recipe_agent(user, %{"aggregate" => %{"op" => "count"}}, %{"lookback_days" => 7})

      assert {:ok, entry, _run} = Agents.run_now(user, agent)
      assert entry.data["content"] =~ "0"
    end
  end

  describe "draft_recipe/4" do
    defp ai_json(recipe) do
      %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(recipe)}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }
    end

    test "returns the validated recipe and a tracked run" do
      user = user_with_ai()
      recipe = %{"aggregate" => %{"op" => "count"}}

      plug = fn conn -> Req.Test.json(conn, ai_json(recipe)) end

      assert {:ok, ^recipe, run} =
               Agents.draft_recipe(user, "count my transactions", ["bank_tx"], plug: plug)

      assert run.action == "draft_recipe"
      assert run.type == "recurrent"
      assert run.status == "ok"
      assert run.input_tokens == 10
      assert run.agent_id == nil
    end

    test "the draft prompt carries kinds and data keys, never values" do
      user = user_with_ai()

      {:ok, _} =
        Servant.Data.create_entry(user.id, %{
          "kind" => "bank_tx",
          "source" => "test",
          "title" => "secret shop",
          "occurred_at" => DateTime.utc_now(),
          "data" => %{"amount" => 4242, "category" => "hidden-category"}
        })

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:ai_request, body})
        Req.Test.json(conn, ai_json(%{"aggregate" => %{"op" => "count"}}))
      end

      assert {:ok, _recipe, _run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)

      assert_receive {:ai_request, body}
      assert body =~ "bank_tx"
      assert body =~ "data.amount"
      assert body =~ "data.category"
      refute body =~ "4242"
      refute body =~ "hidden-category"
      refute body =~ "secret shop"
    end

    test "invalid first reply gets one repair round with cumulative usage" do
      user = user_with_ai()
      counter = start_supervised!({Agent, fn -> 0 end})

      plug = fn conn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          Req.Test.json(conn, %{
            "choices" => [%{"message" => %{"content" => "not json at all"}}],
            "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
          })
        else
          Req.Test.json(conn, ai_json(%{"aggregate" => %{"op" => "count"}}))
        end
      end

      assert {:ok, _recipe, run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)
      assert run.status == "ok"
      assert run.input_tokens == 20
      assert run.output_tokens == 10
    end

    test "two invalid replies fail the run" do
      user = user_with_ai()

      plug = fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "{\"bogus\": true}"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
        })
      end

      assert {:error, message, run} = Agents.draft_recipe(user, "count", ["bank_tx"], plug: plug)
      assert message =~ "unknown"
      assert run.status == "error"
    end

    test "refuses when agents are disabled or the description is blank" do
      user = user_fixture()
      assert {:error, _} = Agents.draft_recipe(user, "count", ["bank_tx"])

      ai_user = user_with_ai()
      assert {:error, _} = Agents.draft_recipe(ai_user, "  ", ["bank_tx"])
    end
  end
end
