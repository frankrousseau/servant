defmodule ServantWeb.AgentControllerTest do
  use ServantWeb.ConnCase

  alias Servant.Accounts
  alias Servant.Agents

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)

    {:ok, _} =
      Accounts.update_ai_config(user, %{
        "enabled" => true,
        "model" => "test-model",
        "base_url" => "http://localhost:9/v1"
      })

    %{conn: conn, user: user}
  end

  defp wait_for_agent_tasks do
    for pid <- Task.Supervisor.children(Servant.Agents.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  @valid %{
    "name" => "Weekly spend",
    "prompt" => "Summarize my spending",
    "kinds" => ["bank_tx"],
    "schedule" => "every_week"
  }

  test "403 on every route when agents are disabled" do
    {conn, _user} = register_and_log_in_user(build_conn())

    assert conn |> get("/api/agents") |> json_response(403)
    assert conn |> post("/api/agents", @valid) |> json_response(403)
    assert conn |> get("/api/agents/runs") |> json_response(403)
    assert conn |> get("/api/agents/runs/x") |> json_response(403)
    assert conn |> post("/api/agents/x/run") |> json_response(403)
  end

  test "CRUD round-trip", %{conn: conn} do
    conn2 = post(conn, "/api/agents", @valid)
    assert %{"data" => created} = json_response(conn2, 201)
    assert created["name"] == "Weekly spend"
    assert created["kinds"] == ["bank_tx"]
    assert created["enabled"] == true

    assert %{"data" => [_]} = conn |> get("/api/agents") |> json_response(200)

    conn3 = put(conn, "/api/agents/#{created["id"]}", %{"enabled" => false})
    assert json_response(conn3, 200)["data"]["enabled"] == false

    assert conn |> delete("/api/agents/#{created["id"]}") |> response(204)
    assert conn |> get("/api/agents") |> json_response(200) == %{"data" => []}
  end

  test "422 on invalid attrs", %{conn: conn} do
    conn = post(conn, "/api/agents", %{@valid | "kinds" => []})
    assert json_response(conn, 422)
  end

  test "404 on another user's agent", %{conn: conn} do
    other = user_fixture()
    {:ok, agent} = Agents.create_agent(other.id, @valid)

    assert conn |> get("/api/agents/#{agent.id}") |> json_response(404)
    assert conn |> post("/api/agents/#{agent.id}/run") |> json_response(404)
  end

  test "manual run returns a pollable 202", %{conn: conn, user: user} do
    {:ok, agent} = Agents.create_agent(user.id, @valid)

    conn2 = post(conn, "/api/agents/#{agent.id}/run")
    assert %{"data" => %{"id" => run_id, "status" => "running"}} = json_response(conn2, 202)

    conn3 = get(conn, "/api/agents/runs/#{run_id}")
    assert %{"data" => data} = json_response(conn3, 200)
    assert data["type"] == "recurrent"
    assert data["agent_id"] == agent.id

    wait_for_agent_tasks()
  end

  test "run on a disabled agent is a 422", %{conn: conn, user: user} do
    {:ok, agent} = Agents.create_agent(user.id, Map.put(@valid, "enabled", false))
    conn = post(conn, "/api/agents/#{agent.id}/run")
    assert %{"error" => _} = json_response(conn, 422)
  end

  test "runs list filters by type", %{conn: conn, user: user} do
    {:ok, _} =
      Agents.create_run(user.id, %{type: "builder", action: "create", status: "ok", model: "m"})

    {:ok, agent} = Agents.create_agent(user.id, @valid)

    {:ok, _} =
      Agents.create_run(user.id, %{
        type: "recurrent",
        action: "report",
        status: "ok",
        model: "m",
        agent_id: agent.id
      })

    assert [run] =
             json_response(get(conn, "/api/agents/runs", %{"type" => "recurrent"}), 200)["data"]

    assert run["type"] == "recurrent"

    assert [run2] =
             json_response(get(conn, "/api/agents/runs", %{"agent_id" => agent.id}), 200)["data"]

    assert run2["agent_id"] == agent.id

    assert json_response(get(conn, "/api/agents/runs", %{"agent_id" => "junk"}), 200)["data"] ==
             []

    assert length(json_response(get(conn, "/api/agents/runs"), 200)["data"]) == 2
  end

  describe "POST /api/agents/draft_recipe" do
    test "422 with a blank description", %{conn: conn} do
      conn = post(conn, ~p"/api/agents/draft_recipe", %{"description" => " ", "kinds" => ["x"]})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "recipe agents over the API" do
    test "creates and returns a recipe agent", %{conn: conn} do
      params = %{
        "name" => "Weekly spend",
        "mode" => "recipe",
        "kinds" => ["bank_tx"],
        "recipe" => %{"aggregate" => %{"op" => "count"}}
      }

      conn = post(conn, ~p"/api/agents", params)
      body = json_response(conn, 201)

      assert body["data"]["mode"] == "recipe"
      assert body["data"]["recipe"] == %{"aggregate" => %{"op" => "count"}}
    end

    test "invalid recipe is a 422", %{conn: conn} do
      params = %{
        "name" => "Bad",
        "mode" => "recipe",
        "kinds" => ["bank_tx"],
        "recipe" => %{"nope" => 1}
      }

      conn = post(conn, ~p"/api/agents", params)
      assert %{"errors" => %{"recipe" => _}} = json_response(conn, 422)
    end
  end
end
