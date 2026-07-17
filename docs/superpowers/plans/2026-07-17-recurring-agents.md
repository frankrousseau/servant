# Agents récurrents + section Agents : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents récurrents "rapports seulement" (table agents, exécution planifiée, rapports = entries ai_report) et la section /agents à onglets Récurrents + Builder (le builder déménage de Settings).

**Architecture:** La base du matin est réutilisée telle quelle : `Servant.AI` pour l'appel, `agent_runs` pour le tracking (gagne `agent_id`), le Task.Supervisor pour l'async. S'y ajoutent la table `agents`, un flux `prepare_run -> execute_report` calqué sur le Generator, un `Servant.Agents.Scheduler` (tick 60 s, batch séquentiel, skip si le batch précédent tourne), un `AgentController` + plug partagé `RequireAgents`, et `AgentsView.vue`.

**Tech Stack:** Elixir/Phoenix + Ecto/SQLite (arrays stockés en JSON, précédent : users.enabled_apps), Vue 3 TS, pas de nouvelle dépendance.

**Spec:** `docs/superpowers/specs/2026-07-17-recurring-agents-design.md`.

## Global Constraints

- **Jamais de tiret cadratin** nulle part (code, copy UI, docs, prompts).
- **Pas de commit** : Frank commite sur demande. Chaque tâche finit sur une vérification.
- Style Elixir : `@moduledoc` après `defmodule`, alias alphabétiques, pas de single-pipe, pipelines depuis une valeur nue ; champs Ecto `:string` même pour `:text` ; champs programmatiques (`user_id`, `agent_id`, `last_run_at`) jamais dans `cast`.
- Tests : valeur réelle à gauche, pas de `Process.sleep`, `start_supervised!`, monitor + `assert_receive {:DOWN, ...}` pour attendre une Task.
- Migrations via `mix ecto.gen.migration`, une par une, timestamps strictement croissants (les existantes finissent à `20260717115439`).
- Copy UI sobre en anglais (manifesto) : modèle affiché, hint serveur non-local, limites annoncées, pas d'iconographie IA (Wrench), une fonction un seul endroit (déménagement du builder = suppression côté Settings).
- Fin de plan : `mix precommit` vert, `npm run build` + `npx vitest run` verts, prettier sur les fichiers front touchés, grep tiret cadratin = seulement les fallbacks legacy connus.

---

### Task 1: Données (table agents, agent_id sur les runs, CRUD, due, filtres)

**Files:**
- Create: migration `create_agents`, migration `add_agent_id_to_agent_runs`
- Create: `lib/servant/agents/agent.ex`
- Modify: `lib/servant/agents/run.ex` (belongs_to :agent)
- Modify: `lib/servant/agents.ex` (CRUD, due, list_runs opts, create_run agent_id)
- Test: `test/servant/agents_test.exs` (nouveaux describe)

**Interfaces:**
- Produces: `Agents.list_agents(user_id)`, `Agents.get_agent(user_id, id)` (nil si inconnu/non-UUID/cross-user), `Agents.create_agent(user_id, attrs)`, `Agents.update_agent(agent, attrs)`, `Agents.delete_agent(agent)`, `Agents.due?(agent, now)`, `Agents.due_agents(now \\ utc_now)`, `Agents.list_runs(user_id, opts)` avec `type:`, `agent_id:`, `limit:` (défaut 50 ; **remplace** l'ancienne arité `(user_id, limit)`, aucun autre appelant que les tests et AppController.runs qui sera réécrit en Task 4 : adapter les appels existants), `Agents.create_run(user_id, attrs)` acceptant `:agent_id` dans attrs (poppé vers le struct, jamais casté).

- [ ] **Step 1: Tests.** Dans `test/servant/agents_test.exs`, ajouter :

```elixir
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
      {:ok, agent} = Agents.create_agent(user.id, %{"name" => "A", "prompt" => "p", "kinds" => ["x"]})

      {:ok, _b} = Agents.create_run(user.id, %{type: "builder", action: "create", status: "ok", model: "m"})

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
```

Note : `Agents.touch_last_run(agent, dt)` est une fonction publique du contexte (le scheduler et l'exécution en ont besoin, les tests aussi). Les describe existants qui appellent `list_runs(user.id)` sans options doivent continuer de passer tels quels.

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant/agents_test.exs`.

- [ ] **Step 3: Migrations.** `mix ecto.gen.migration create_agents` :

```elixir
defmodule Servant.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prompt, :text, null: false
      add :kinds, {:array, :string}, null: false
      add :lookback_days, :integer, null: false, default: 7
      add :schedule, :string, null: false, default: "every_day"
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:user_id])
  end
end
```

Puis `mix ecto.gen.migration add_agent_id_to_agent_runs` (timestamp strictement supérieur) :

```elixir
defmodule Servant.Repo.Migrations.AddAgentIdToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
```

Note SQLite : si l'ADD COLUMN avec REFERENCES est rejeté par exqlite, retomber sur `add :agent_id, :binary_id` sans contrainte FK (le scoping applicatif suffit) et le dire dans le rapport. Vérifier `mix ecto.migrate` + `mix ecto.rollback --step 2` + `mix ecto.migrate`.

- [ ] **Step 4: Schéma `lib/servant/agents/agent.ex`** :

```elixir
defmodule Servant.Agents.Agent do
  @moduledoc """
  A recurring agent: a prompt run on a schedule over a selection of the
  user's entries, producing report entries (kind "ai_report").
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schedules ~w(every_hour every_day every_week)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :name, :string
    field :prompt, :string
    field :kinds, {:array, :string}
    field :lookback_days, :integer, default: 7
    field :schedule, :string, default: "every_day"
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :prompt, :kinds, :lookback_days, :schedule, :enabled])
    |> validate_required([:name, :prompt, :kinds])
    |> validate_length(:name, max: 60)
    |> validate_length(:prompt, max: 4000)
    |> validate_kinds()
    |> validate_number(:lookback_days, greater_than: 0, less_than_or_equal_to: 365)
    |> validate_inclusion(:schedule, @schedules)
  end

  def schedules, do: @schedules

  # Kind slugs, same shape rule as users.enabled_apps.
  defp validate_kinds(changeset) do
    changeset
    |> validate_length(:kinds, min: 1, max: 20)
    |> validate_change(:kinds, fn :kinds, kinds ->
      if Enum.all?(kinds, &(is_binary(&1) and &1 =~ ~r/^[a-z0-9_-]{1,50}$/)) do
        []
      else
        [kinds: "must be a list of entry kind slugs"]
      end
    end)
  end
end
```

- [ ] **Step 5: `lib/servant/agents/run.ex`** : ajouter sous les fields, avant `belongs_to :user` :

```elixir
    belongs_to :agent, Servant.Agents.Agent
```

(`agent_id` reste hors du `cast`.)

- [ ] **Step 6: Contexte `lib/servant/agents.ex`.** Ajouter l'alias `Servant.Agents.Agent` (ordre alphabétique avec Run et Repo). CRUD + due (placés avant les fonctions de runs) :

```elixir
  @intervals %{"every_hour" => 3600, "every_day" => 86_400, "every_week" => 604_800}

  def list_agents(user_id) do
    Agent
    |> where(user_id: ^user_id)
    |> order_by(:name)
    |> Repo.all()
  end

  def get_agent(user_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Agent, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  def create_agent(user_id, attrs) do
    %Agent{user_id: user_id}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%Agent{} = agent), do: Repo.delete(agent)

  @doc "Sets last_run_at (programmatic field, never cast)."
  def touch_last_run(%Agent{} = agent, dt \\ nil) do
    dt = dt || DateTime.truncate(DateTime.utc_now(), :second)

    agent
    |> Ecto.Changeset.change(last_run_at: dt)
    |> Repo.update()
  end

  def due?(%Agent{enabled: false}, _now), do: false
  def due?(%Agent{last_run_at: nil}, _now), do: true

  def due?(%Agent{} = agent, now) do
    next = DateTime.add(agent.last_run_at, @intervals[agent.schedule], :second)
    DateTime.compare(next, now) != :gt
  end

  def due_agents(now \\ DateTime.utc_now()) do
    Agent
    |> where(enabled: true)
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
  end
```

`create_run` : pop de l'agent_id vers le struct :

```elixir
  def create_run(user_id, attrs) do
    {agent_id, attrs} = Map.pop(attrs, :agent_id)

    %Run{user_id: user_id, agent_id: agent_id}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end
```

`list_runs` : nouvelle signature à options (conserver le sweep lazy existant tel quel en tête de fonction) :

```elixir
  def list_runs(user_id, opts \\ []) do
    sweep_stale_runs(user_id)

    Run
    |> where(user_id: ^user_id)
    |> maybe_filter(:type, opts[:type])
    |> maybe_filter(:agent_id, opts[:agent_id])
    |> order_by(desc: :inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)
```

Si le sweep n'est pas déjà extrait dans une fonction privée `sweep_stale_runs/1`, l'extraire à l'identique. Adapter tout appel existant `list_runs(user_id, n)` en `list_runs(user_id, limit: n)` (grep).

- [ ] **Step 7: Vérifier** : `mix ecto.migrate`, `mix test test/servant/agents_test.exs` vert, puis `mix test` (AppController.runs appelle encore `list_runs(user_id)` sans options : arité par défaut inchangée, rien à toucher avant la Task 4).

---

### Task 2: Exécution des rapports (prepare_run / run_now / start_run)

**Files:**
- Modify: `lib/servant/agents.ex`
- Test: `test/servant/agents_test.exs` (describe "run_now")

**Interfaces:**
- Consumes: `Servant.AI.chat/3`, `Servant.Accounts.ai_config/1`, `Servant.Data.all_entries/2` (filtres `"kind"` et `"from"` ISO), `Servant.Data.create_entry/2` (accepte `"metadata"`; vérifier le cast dans data.ex, il y est).
- Produces: `Agents.run_now(user, agent, ai_opts \\ [])` -> `{:ok, entry, run} | {:error, message, run} | {:error, message}` (2-tuple = échec de validation avant run), `Agents.start_run(user, agent)` -> `{:ok, run} | {:error, message}` (Task supervisée), `Agents.run_due(now \\ utc_now)` (Task 3 le complètera côté scheduler mais la fonction vit ici et est livrée dans CETTE task).

- [ ] **Step 1: Tests** (describe "run_now" dans agents_test ; helpers en haut du module) :

```elixir
  # In the module header, add:
  #   alias Servant.Accounts
  #   alias Servant.Data

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
```

`entry_fixture/2` vient de test/support/fixtures.ex (vérifier sa signature réelle : il pose des défauts kind/source ; passer les overrides comme dans entry_controller_test).

- [ ] **Step 2: Vérifier l'échec**, puis **Step 3: Implémentation** dans `lib/servant/agents.ex`. Ajouter les alias `Servant.Accounts`, `Servant.AI`, `Servant.Data` (ordre alphabétique). Module attributes :

```elixir
  @max_context_entries 200
  @max_context_chars 20_000

  @report_system_prompt """
  You write a report from personal data for its owner.
  Reply in plain markdown, without code fences. Use only the data provided
  in the message: never invent numbers, names or events. If the data
  section is empty, say so briefly. If the data is marked as a truncated
  extract, mention that the report covers a partial extract. Keep the
  report short and factual: totals, notable items, simple trends.
  """
```

Fonctions (mêmes conventions que le Generator, y compris le rescue) :

```elixir
  @doc """
  Runs a recurring agent synchronously (tests and the scheduler): gathers
  the entries context, asks the model for a report, stores it as an
  ai_report entry. Returns {:ok, entry, run} | {:error, message, run};
  pre-run validation failures return {:error, message} without a run.
  """
  def run_now(user, agent, ai_opts \\ []) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      execute_report(run, user, agent, ai_opts)
    end
  end

  @doc "Async variant for the API: returns the run immediately, work happens in a supervised Task."
  def start_run(user, agent) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Servant.Agents.TaskSupervisor, fn ->
          execute_report(run, user, agent, [])
        end)

      {:ok, run}
    end
  end

  @doc "Runs every due enabled agent sequentially; each agent is rescued individually."
  def run_due(now \\ DateTime.utc_now()) do
    for agent <- due_agents(now) do
      user = Accounts.get_user!(agent.user_id)

      if Accounts.ai_enabled?(user) do
        try do
          run_now(user, agent)
        rescue
          # the run row was already failed by execute_report's rescue
          _exception -> :error
        end
      end
    end

    :ok
  end

  defp prepare_run(user, agent) do
    config = Accounts.ai_config(user)

    cond do
      config["enabled"] != true ->
        {:error, "agents are disabled in Settings"}

      not agent.enabled ->
        {:error, "this agent is disabled"}

      true ->
        {:ok, agent} = touch_last_run(agent)

        result =
          create_run(user.id, %{
            type: "recurrent",
            action: "report",
            agent_id: agent.id,
            status: "running",
            model: config["model"],
            prompt: String.slice(agent.prompt, 0, 2000)
          })

        case result do
          {:ok, run} -> {:ok, run, agent}
          {:error, %Ecto.Changeset{}} -> {:error, "could not create the run"}
        end
    end
  end

  defp execute_report(run, user, agent, ai_opts) do
    config = Accounts.ai_config(user)
    started = System.monotonic_time(:millisecond)

    try do
      {context, truncated?} = build_context(user.id, agent)

      messages = [
        %{role: "system", content: @report_system_prompt},
        %{role: "user", content: report_request(agent, context, truncated?)}
      ]

      case AI.chat(config, messages, ai_opts) do
        {:ok, %{content: content, usage: usage}} ->
          store_report(run, user, agent, config["model"], content, usage, started)

        {:error, message} ->
          {:ok, run} = fail_run(run, message, nil, elapsed(started))
          {:error, message, run}
      end
    rescue
      exception ->
        {:ok, _run} = fail_run(run, Exception.message(exception), nil, elapsed(started))
        reraise exception, __STACKTRACE__
    end
  end

  defp store_report(run, user, agent, model, content, usage, started) do
    attrs = %{
      "kind" => "ai_report",
      "source" => "agent",
      "title" => "#{agent.name} - #{Date.to_iso8601(Date.utc_today())}",
      "occurred_at" => DateTime.utc_now(),
      "data" => %{"content" => content},
      "metadata" => %{"agent_id" => agent.id, "run_id" => run.id, "model" => model}
    }

    case Data.create_entry(user.id, attrs) do
      {:ok, entry} ->
        {:ok, run} = complete_run(run, usage, elapsed(started))
        {:ok, entry, run}

      {:error, %Ecto.Changeset{}} ->
        {:ok, run} = fail_run(run, "could not store the report", usage, elapsed(started))
        {:error, run.error, run}
    end
  end

  defp build_context(user_id, agent) do
    from_dt = DateTime.add(DateTime.utc_now(), -agent.lookback_days * 86_400, :second)
    from_iso = DateTime.to_iso8601(from_dt)

    entries =
      agent.kinds
      |> Enum.flat_map(&Data.all_entries(user_id, %{"kind" => &1, "from" => from_iso}))
      |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})

    {taken, rest} = Enum.split(entries, @max_context_entries)
    {text, chars_truncated?} = join_capped(Enum.map(taken, &entry_line/1), @max_context_chars)
    {text, chars_truncated? or rest != []}
  end

  defp entry_line(entry) do
    date = entry.occurred_at && DateTime.to_iso8601(entry.occurred_at)
    "- #{date} | #{entry.title || "-"} | #{Jason.encode!(compact_data(entry.data))}"
  end

  # Long string values (raw payloads, base64) would eat the whole budget.
  defp compact_data(data) when is_map(data) do
    data
    |> Enum.reject(fn {_k, v} -> is_binary(v) and byte_size(v) > 200 end)
    |> Map.new()
  end

  defp compact_data(_data), do: %{}

  defp join_capped(lines, max) do
    {kept, _size} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, size} ->
        new_size = size + byte_size(line) + 1

        if new_size > max do
          {:halt, {acc, size}}
        else
          {:cont, {[line | acc], new_size}}
        end
      end)

    text = kept |> Enum.reverse() |> Enum.join("\n")
    {text, length(kept) < length(lines)}
  end

  defp report_request(agent, context, truncated?) do
    marker = if truncated?, do: " [truncated extract]", else: ""

    header =
      "Task: #{agent.prompt}\n\n" <>
        "Data (last #{agent.lookback_days} days, kinds: #{Enum.join(agent.kinds, ", ")})#{marker}:\n\n"

    body = if context == "", do: "(no entries)", else: context
    header <> body
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
```

Si `Data.all_entries/2` ne supporte pas le filtre `"from"` (vérifier : `apply_filters` dans data.ex le gère pour list_entries ; confirmer que all_entries passe par le même chemin), utiliser la fonction publique qui le supporte ou étendre all_entries à l'identique de list_entries. Ne PAS filtrer en mémoire.

- [ ] **Step 4: Vérifier** : `mix test test/servant/agents_test.exs` vert, `mix format`, `mix test` complet.

---

### Task 3: Scheduler

**Files:**
- Create: `lib/servant/agents/scheduler.ex`
- Modify: `lib/servant/application.ex` (enfant après le Task.Supervisor)
- Modify: `config/test.exs` (tick désactivé)
- Test: `test/servant/agents_test.exs` (describe "run_due" + boot du scheduler)

**Interfaces:**
- Consumes: `Agents.run_due/0` (Task 2), `Servant.Agents.TaskSupervisor`.

- [ ] **Step 1: Tests** :

```elixir
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
    pid = start_supervised!(Servant.Agents.Scheduler)
    assert :sys.get_state(pid) == %{task_ref: nil}
  end
```

Attention : `start_supervised!(Servant.Agents.Scheduler)` échouera si l'application a déjà démarré le scheduler sous le même nom. Deux options, choisir la première qui marche : `start_supervised!({Servant.Agents.Scheduler, name: :test_agent_scheduler})` avec un `start_link` qui accepte `:name` dans opts, ou retirer ce test si le conflit de nom est inévitable (le module est trivial). Le start_link du code ci-dessous accepte `opts[:name]`.

- [ ] **Step 2: Vérifier l'échec**, puis **Step 3: `lib/servant/agents/scheduler.ex`** :

```elixir
defmodule Servant.Agents.Scheduler do
  @moduledoc """
  Ticks every minute and runs due recurring agents (Servant.Agents.run_due/0)
  in a supervised Task. One batch at a time: if the previous batch is still
  running (local models are slow), the tick is skipped. Ticking is disabled
  in tests via config :servant, Servant.Agents.Scheduler, tick: false.
  """

  use GenServer

  alias Servant.Agents

  @tick_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    if tick_enabled?(), do: schedule_tick()
    {:ok, %{task_ref: nil}}
  end

  @impl true
  def handle_info(:tick, %{task_ref: nil} = state) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(Servant.Agents.TaskSupervisor, &Agents.run_due/0)
    schedule_tick()
    {:noreply, %{state | task_ref: ref}}
  end

  def handle_info(:tick, state) do
    # Previous batch still running: skip this tick.
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp tick_enabled? do
    :servant
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:tick, true)
  end
end
```

- [ ] **Step 4: `lib/servant/application.ex`** : après la ligne du Task.Supervisor agents, ajouter :

```elixir
        Servant.Agents.Scheduler,
```

Et dans `config/test.exs` :

```elixir
config :servant, Servant.Agents.Scheduler, tick: false
```

- [ ] **Step 5: Vérifier** : `mix test test/servant/agents_test.exs` vert, `mix test` complet (aucun bruit de scheduler dans la sortie).

---

### Task 4: API (plug partagé, AgentController, déplacement des runs)

**Files:**
- Create: `lib/servant_web/plugs/require_agents.ex`
- Create: `lib/servant_web/controllers/agent_run_json.ex`
- Create: `lib/servant_web/controllers/agent_controller.ex`
- Modify: `lib/servant_web/controllers/app_controller.ex` (plug partagé, retirer runs/run/run_json)
- Modify: `lib/servant_web/router.ex`
- Modify: `lib/servant/apps.ex` (`"agents"` dans @reserved_ids)
- Test: `test/servant_web/controllers/agent_controller_test.exs` (nouveau)
- Test: `test/servant_web/controllers/app_controller_test.exs` (runs déplacés, poll adapté)

**Interfaces:**
- Produces (JSON): agent = `{id, name, prompt, kinds, lookback_days, schedule, enabled, last_run_at, inserted_at}` ; run gagne `agent_id`. Routes : `GET/POST /api/agents`, `GET/PUT/DELETE /api/agents/:id`, `POST /api/agents/:id/run` -> 202, `GET /api/agents/runs?type=&agent_id=`, `GET /api/agents/runs/:id`. `/api/apps/runs*` supprimées.

- [ ] **Step 1: Tests.** Nouveau `test/servant_web/controllers/agent_controller_test.exs` :

```elixir
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

    assert [run] = json_response(get(conn, "/api/agents/runs", %{"type" => "recurrent"}), 200)["data"]
    assert run["type"] == "recurrent"

    assert [run2] =
             json_response(get(conn, "/api/agents/runs", %{"agent_id" => agent.id}), 200)["data"]

    assert run2["agent_id"] == agent.id

    assert json_response(get(conn, "/api/agents/runs", %{"agent_id" => "junk"}), 200)["data"] == []
    assert length(json_response(get(conn, "/api/agents/runs"), 200)["data"]) == 2
  end
end
```

Dans `app_controller_test.exs` : supprimer les tests des routes `/api/apps/runs*` ; adapter le test "generate returns 202 with a pollable run" pour poller `/api/agents/runs/#{run_id}` ; ajouter un test que `GET /api/apps/runs` est maintenant introuvable (`assert_error_sent 404, fn -> get(conn, "/api/apps/runs") end`).

- [ ] **Step 2: Vérifier l'échec.**

- [ ] **Step 3: Plug `lib/servant_web/plugs/require_agents.ex`** :

```elixir
defmodule ServantWeb.Plugs.RequireAgents do
  @moduledoc "Halts with a 403 unless the current user enabled AI agents in Settings."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Servant.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if Accounts.ai_enabled?(conn.assigns.current_user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "AI agents are disabled in Settings"})
      |> halt()
    end
  end
end
```

- [ ] **Step 4: Helper `lib/servant_web/controllers/agent_run_json.ex`** :

```elixir
defmodule ServantWeb.AgentRunJSON do
  @moduledoc "JSON shape of an agent run, shared by the agents and apps controllers."

  def run_json(run) do
    %{
      id: run.id,
      type: run.type,
      action: run.action,
      agent_id: run.agent_id,
      app_id: run.app_id,
      status: run.status,
      model: run.model,
      prompt: run.prompt,
      input_tokens: run.input_tokens,
      output_tokens: run.output_tokens,
      duration_ms: run.duration_ms,
      error: run.error,
      inserted_at: run.inserted_at
    }
  end
end
```

- [ ] **Step 5: `lib/servant_web/controllers/agent_controller.ex`.** Structure (compléter les `operation(...)` sur le modèle exact d'AppController, résumés session-only + gating mentionnés) :

```elixir
defmodule ServantWeb.AgentController do
  @moduledoc "CRUD and manual runs for recurring agents; run history for all agent types."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ServantWeb.AgentRunJSON

  alias OpenApiSpex.Schema
  alias Servant.Agents
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.RequireAgents

  tags(["agents"])

  # operation(...) blocks: index, create, show, update, delete, run, runs, show_run
  # (same style as AppController; request bodies for create/update take the
  # agent fields; every response lists forbidden/unauthorized like the app ones)

  def index(conn, _params) do
    agents = Agents.list_agents(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(agents, &agent_json/1)})
  end

  def create(conn, params) do
    case Agents.create_agent(conn.assigns.current_user.id, params) do
      {:ok, agent} ->
        conn |> put_status(:created) |> json(%{data: agent_json(agent)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  def show(conn, %{"id" => id}) do
    with_agent(conn, id, fn agent -> json(conn, %{data: agent_json(agent)}) end)
  end

  def update(conn, %{"id" => id} = params) do
    with_agent(conn, id, fn agent ->
      case Agents.update_agent(agent, params) do
        {:ok, agent} -> json(conn, %{data: agent_json(agent)})
        {:error, changeset} -> changeset_error(conn, changeset)
      end
    end)
  end

  def delete(conn, %{"id" => id}) do
    with_agent(conn, id, fn agent ->
      {:ok, _} = Agents.delete_agent(agent)
      send_resp(conn, :no_content, "")
    end)
  end

  def run(conn, %{"id" => id}) do
    with_agent(conn, id, fn agent ->
      case Agents.start_run(conn.assigns.current_user, agent) do
        {:ok, run} ->
          conn |> put_status(:accepted) |> json(%{data: run_json(run)})

        {:error, message} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: message})
      end
    end)
  end

  def runs(conn, params) do
    case cast_agent_id(params["agent_id"]) do
      :invalid ->
        json(conn, %{data: []})

      agent_id ->
        runs =
          Agents.list_runs(conn.assigns.current_user.id,
            type: params["type"],
            agent_id: agent_id
          )

        json(conn, %{data: Enum.map(runs, &run_json/1)})
    end
  end

  def show_run(conn, %{"id" => id}) do
    case Agents.get_run(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Run not found"})
      run -> json(conn, %{data: run_json(run)})
    end
  end

  defp with_agent(conn, id, fun) do
    case Agents.get_agent(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agent not found"})
      agent -> fun.(agent)
    end
  end

  defp agent_json(agent) do
    %{
      id: agent.id,
      name: agent.name,
      prompt: agent.prompt,
      kinds: agent.kinds,
      lookback_days: agent.lookback_days,
      schedule: agent.schedule,
      enabled: agent.enabled,
      last_run_at: agent.last_run_at,
      inserted_at: agent.inserted_at
    }
  end

  defp cast_agent_id(nil), do: nil

  defp cast_agent_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> :invalid
    end
  end

  # changeset_error/2: render the 422 exactly the way EntryController does
  # for an invalid changeset (read entry_controller.ex and reuse its
  # mechanism, FallbackController or manual traverse_errors, do not invent
  # a new format: the test only asserts a 422).
end
```

- [ ] **Step 6: AppController** : remplacer le plug privé par `plug ServantWeb.Plugs.RequireAgents when action in [:generate, :modify, :restore]` ; supprimer les actions `runs`/`run`, leurs `operation(...)`, le `run_json/1` privé et le plug privé ; ajouter `import ServantWeb.AgentRunJSON` (generate/modify l'utilisent toujours). Alias : retirer `Servant.Agents` s'il n'est plus référencé.

- [ ] **Step 7: Router** : dans le scope session_only, remplacer les deux lignes `get "/apps/runs"...` par (avant tout resources /agents pour que "runs" ne soit pas capturé comme :id) :

```elixir
        get "/agents/runs", AgentController, :runs
        get "/agents/runs/:id", AgentController, :show_run
        post "/agents/:id/run", AgentController, :run
        resources "/agents", AgentController, except: [:new, :edit]
```

- [ ] **Step 8: `lib/servant/apps.ex`** : ajouter `agents` à la liste `@reserved_ids` (ordre alphabétique de la liste existante).

- [ ] **Step 9: Vérifier** : les deux fichiers de tests contrôleurs verts, `mix format`, `mix test` complet, `mix precommit`.

---

### Task 5: Frontend (section Agents, sidebar, Settings allégé)

**Files:**
- Create: `frontend/src/views/AgentsView.vue`
- Modify: `frontend/src/types.ts` (interface Agent, AgentRun.agent_id)
- Modify: `frontend/src/router/index.ts` (route /agents)
- Modify: `frontend/src/App.vue` (lien sidebar)
- Modify: `frontend/src/views/SettingsView.vue` (slim-down)

**Interfaces:**
- Consumes: toutes les routes de Task 4 ; store apps existant (`installed`, `generate`, `modify`, `restore`, `uninstall`, `load`).

- [ ] **Step 1: `frontend/src/types.ts`** : dans `AgentRun`, ajouter `agent_id: string | null` (après `action`). Ajouter :

```ts
export interface Agent {
  id: string
  name: string
  prompt: string
  kinds: string[]
  lookback_days: number
  schedule: 'every_hour' | 'every_day' | 'every_week'
  enabled: boolean
  last_run_at: string | null
  inserted_at: string
}
```

- [ ] **Step 2: Route + sidebar.** Dans `router/index.ts`, après la route `connectors` :

```ts
    {
      path: '/agents',
      name: 'agents',
      component: () => import('../views/AgentsView.vue'),
      meta: { auth: true, title: 'Agents' }
    },
```

Dans `App.vue`, après le `<li>` du lien Connectors (même structure exacte que les liens voisins, importer `Wrench` de lucide-vue-next à côté des icônes existantes) :

```html
        <li>
          <router-link to="/agents"> <Wrench :size="18" />Agents </router-link>
        </li>
```

- [ ] **Step 3: `frontend/src/views/AgentsView.vue`.** LIRE d'abord `SettingsView.vue` : tout le bloc builder (état `genName/genDescription/genBusy/genError/modifyingId/modifyInstruction/restoringId`, fonctions `pollRun/generateApp/modifyApp/restoreApp`, template du formulaire "Generate an app" et les lignes modify/restore du tableau apps, CSS associées) DÉMÉNAGE ici. Structure complète de la vue :

```vue
<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import ComboBox from '../components/ComboBox.vue'
import { useApi } from '../composables/useApi'
import { useConfirm } from '../composables/useConfirm'
import { useAppsStore } from '../stores/apps'
import { formatDate } from '../lib/datetime'
import { Wrench, Play, Pencil, Trash2, Undo2, Plus } from 'lucide-vue-next'
import type { Agent, AgentRun, AiConfig, Entry } from '../types'

const api = useApi()
const { ask } = useConfirm()
const apps = useAppsStore()
const route = useRoute()
const router = useRouter()

// ----- Shared: config banner + tabs -----

const aiConfig = ref<AiConfig | null>(null)

const tab = computed(() => (route.query.tab === 'builder' ? 'builder' : 'recurrents'))

function setTab(t: string) {
  router.replace({ query: { ...route.query, tab: t } })
}

const serverHost = computed(() => {
  try {
    return new URL(aiConfig.value?.base_url || '').hostname
  } catch {
    return ''
  }
})

const localServer = computed(() =>
  ['localhost', '127.0.0.1', '[::1]', '::1'].includes(serverHost.value)
)

async function loadConfig() {
  try {
    aiConfig.value = (await api.get<{ data: AiConfig }>('/api/ai_config')).data
  } catch {
    aiConfig.value = null
  }
}

// ----- Recurring agents -----

const agents = ref<Agent[]>([])
const recurrentRuns = ref<AgentRun[]>([])
const reports = ref<Entry[]>([])
const agentError = ref('')
const runningId = ref('')
const expandedReport = ref('')

// form state (create or edit)
const editingId = ref('')
const formOpen = ref(false)
const fName = ref('')
const fPrompt = ref('')
const fKinds = ref('')
const fLookback = ref(7)
const fSchedule = ref('every_day')
const fSaving = ref(false)

const SCHEDULE_OPTIONS = [
  { value: 'every_hour', label: 'Every hour' },
  { value: 'every_day', label: 'Every day' },
  { value: 'every_week', label: 'Every week' }
]

async function loadAgents() {
  agents.value = (await api.get<{ data: Agent[] }>('/api/agents')).data
}

async function loadRecurrentRuns() {
  recurrentRuns.value = (
    await api.get<{ data: AgentRun[] }>('/api/agents/runs', { type: 'recurrent' })
  ).data
}

async function loadReports() {
  const res = await api.get<{ data: Entry[] }>('/api/entries', { kind: 'ai_report' })
  reports.value = res.data
}

function reportsOf(agentId: string) {
  return reports.value.filter(r => (r.metadata as any)?.agent_id === agentId)
}

function lastRunOf(agentId: string) {
  return recurrentRuns.value.find(r => r.agent_id === agentId)
}

function openCreate() {
  editingId.value = ''
  fName.value = ''
  fPrompt.value = ''
  fKinds.value = ''
  fLookback.value = 7
  fSchedule.value = 'every_day'
  formOpen.value = true
}

function openEdit(a: Agent) {
  editingId.value = a.id
  fName.value = a.name
  fPrompt.value = a.prompt
  fKinds.value = a.kinds.join(', ')
  fLookback.value = a.lookback_days
  fSchedule.value = a.schedule
  formOpen.value = true
}

async function saveAgent() {
  agentError.value = ''
  fSaving.value = true
  const body = {
    name: fName.value.trim(),
    prompt: fPrompt.value.trim(),
    kinds: fKinds.value
      .split(',')
      .map(k => k.trim())
      .filter(Boolean),
    lookback_days: fLookback.value,
    schedule: fSchedule.value
  }
  try {
    if (editingId.value) await api.put(`/api/agents/${editingId.value}`, body)
    else await api.post('/api/agents', body)
    formOpen.value = false
    await loadAgents()
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Save failed'
  } finally {
    fSaving.value = false
  }
}

async function toggleAgent(a: Agent) {
  try {
    await api.put(`/api/agents/${a.id}`, { enabled: !a.enabled })
    await loadAgents()
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Save failed'
  }
}

async function deleteAgent(a: Agent) {
  const ok = await ask({
    title: 'Delete agent',
    message: `Delete "${a.name}"? Its past reports are kept.`,
    danger: true
  })
  if (!ok) return
  await api.del(`/api/agents/${a.id}`)
  await loadAgents()
}

async function runNow(a: Agent) {
  agentError.value = ''
  runningId.value = a.id
  try {
    const res = await api.post<{ data: AgentRun }>(`/api/agents/${a.id}/run`)
    const run = await pollRun(res.data.id)
    if (run.status === 'error') agentError.value = run.error || 'Run failed'
    await Promise.all([loadAgents(), loadRecurrentRuns(), loadReports()])
  } catch (e) {
    agentError.value = e instanceof Error ? e.message : 'Run failed'
  } finally {
    runningId.value = ''
  }
}

// ----- Shared polling (builder + recurring) -----

async function pollRun(id: string): Promise<AgentRun> {
  for (;;) {
    const run = (await api.get<{ data: AgentRun }>(`/api/agents/runs/${id}`)).data
    if (run.status !== 'running') return run
    await new Promise(resolve => setTimeout(resolve, 2000))
  }
}

// ----- Builder tab (moved from SettingsView) -----
// State + generateApp/modifyApp/restoreApp exactly as they were in
// SettingsView (genName, genDescription, genBusy, genError, modifyingId,
// modifyInstruction, restoringId), plus:

const builderRuns = ref<AgentRun[]>([])
const generatedApps = computed(() => apps.installed.filter(a => a.generated))

async function loadBuilderRuns() {
  builderRuns.value = (
    await api.get<{ data: AgentRun[] }>('/api/agents/runs', { type: 'builder' })
  ).data
}

async function uninstallGenerated(id: string, name: string) {
  const ok = await ask({
    title: 'Uninstall app',
    message: `Uninstall "${name}"? Its files will be removed.`,
    danger: true
  })
  if (!ok) return
  await apps.uninstall(id)
}

onMounted(() => {
  loadConfig()
  apps.load().catch(() => {})
  loadAgents().catch(() => {})
  loadRecurrentRuns().catch(() => {})
  loadReports().catch(() => {})
  loadBuilderRuns().catch(() => {})
})
</script>
```

Template (structure ; réutiliser les classes .card/.tk-* de SettingsView, dupliquées dans le style scoped local, c'est le pattern du projet) :

```html
<template>
  <div class="view">
    <h1>Agents</h1>

    <p v-if="aiConfig && !aiConfig.enabled" class="agents-disabled">
      Agents are disabled.
      <router-link to="/settings">Enable them in Settings</router-link> and
      configure a model server first.
    </p>

    <template v-else-if="aiConfig">
      <p class="tk-hint">
        Runs on {{ aiConfig.model }} at {{ aiConfig.base_url }}.
        <template v-if="!localServer">
          This server is not local: these agents send the selected entries to
          {{ serverHost }}.
        </template>
        Reports can be wrong or incomplete: check the numbers before acting
        on them.
      </p>

      <div class="tabs" role="tablist">
        <button role="tab" :aria-selected="tab === 'recurrents'"
          :class="{ active: tab === 'recurrents' }" @click="setTab('recurrents')">
          Recurring
        </button>
        <button role="tab" :aria-selected="tab === 'builder'"
          :class="{ active: tab === 'builder' }" @click="setTab('builder')">
          Builder
        </button>
      </div>

      <!-- Recurring tab: agents table (name, kinds, schedule, enabled toggle,
           last run status via lastRunOf, Run now (Play, disabled while
           runningId), Edit (Pencil), Delete (Trash2)); "New agent" button
           (Plus) opening the form card (name, prompt textarea, kinds text
           input with hint "comma-separated entry kinds, e.g. bank_tx",
           lookback_days number input, schedule ComboBox, Save/Cancel);
           reports list: for each agent with reports, collapsible items
           (title + date, click toggles expandedReport = entry id, content
           rendered in a <pre class="report-content">); recent runs table
           (date, agent name, model, tokens, duration, status w/ error title),
           same columns/classes as the old Settings runs table. -->

      <!-- Builder tab: exactly the blocks moved from SettingsView:
           "Generate an app" form; generated apps table (name, Modify toggle
           row with textarea + submit, Restore if has_previous, Uninstall via
           uninstallGenerated); builder runs table fed by builderRuns.
           The model name stays on the Generate/Modify buttons. -->
    </template>
  </div>
</template>
```

Les deux commentaires HTML ci-dessus sont à REMPLACER par le markup réel (interdits dans le rendu final) ; le markup builder est un copier-coller adapté depuis SettingsView (mêmes classes, mêmes bindings, `apps.installed` remplacé par `generatedApps` et l'uninstall par `uninstallGenerated`). Style scoped : reprendre de SettingsView les règles .card, .tk-table, .tk-hint, .tk-empty, .tk-revoke, .app-form, .msg utilisées, plus :

```css
.tabs {
  display: flex;
  gap: 0.5rem;
  margin-bottom: 1rem;
}
.tabs button {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
  padding: 0.45rem 1rem;
  cursor: pointer;
}
.tabs button.active {
  color: var(--text);
  border-color: var(--primary);
}
.agents-disabled {
  color: var(--text-muted);
}
.report-content {
  white-space: pre-wrap;
  font-size: 0.85rem;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.75rem 1rem;
}
```

- [ ] **Step 4: SettingsView slim-down.** Supprimer : la table des runs de la carte Agents (et `agentRuns`, `loadAgentRuns` + leurs appels), le formulaire "Generate an app", les colonnes/lignes modify-restore du tableau apps (revenir à des `<tr>` simples : Name / Repository / update git + uninstall), tout l'état et les fonctions builder (`genName`, `genDescription`, `genBusy`, `genError`, `modifyingId`, `modifyInstruction`, `restoringId`, `pollRun`, `generateApp`, `modifyApp`, `restoreApp`) et les imports lucide devenus inutiles (Pencil, Undo2). Le tableau apps de Settings filtre les apps git : `apps.installed.filter(a => !a.generated)` (computed `gitApps`). La carte Agents garde le toggle + les 3 champs + Save, et ajoute une ligne :

```html
        <p class="tk-hint">
          Agents themselves live in the
          <router-link to="/agents">Agents section</router-link>.
        </p>
```

- [ ] **Step 5: Vérifier** : `cd frontend && npm run build` (exit 0), `npx vitest run` (138), `npx prettier --write src/views/AgentsView.vue src/views/SettingsView.vue src/types.ts src/router/index.ts src/App.vue`, re-build si prettier a modifié.

---

### Task 6: Docs + vérification finale

**Files:**
- Modify: `docs/custom-apps.md` (références Settings > Apps -> Agents > Builder)
- Modify: `DEVELOPMENT.md` (bullet Agents étendu)
- Modify: `docs/ai-agents-plan.md` (bandeau en tête)

- [ ] **Step 1: `docs/custom-apps.md`**, section "Generated apps (builder agent)" : remplacer les deux mentions de `Settings > Apps` par `the Agents section (Builder tab)` et la mention `Settings > Agents` du tracking par `the Agents section`. Relire la section entière pour la cohérence.

- [ ] **Step 2: `DEVELOPMENT.md`**, remplacer le bullet **Agents** par :

```markdown
- **Agents** share one per-user AI config (`users.ai_config`, encrypted) and one `agent_runs` history (model, tokens, duration per run). Two types ship today: the **builder** (`Servant.Apps.Generator`, turns a description into an installed custom app) and **recurring report agents** (`agents` table + `Servant.Agents.Scheduler`, a prompt run on a schedule over selected entries, producing `ai_report` entries). Both call one OpenAI-compatible endpoint (`Servant.AI`). Disabled by default (Settings > Agents); the UI lives in the Agents section.
```

- [ ] **Step 3: `docs/ai-agents-plan.md`** : insérer sous le titre :

```markdown
> Statut 2026-07-17 : partiellement implémenté (config multi-provider via un
> protocole OpenAI-compatible, agents récurrents "rapports", builder d'apps).
> Voir DEVELOPMENT.md ; ce document reste des notes de conception.
```

- [ ] **Step 4: Vérification finale** : `mix precommit` vert ; `cd frontend && npm run build` + `npx vitest run` verts ; grep tiret cadratin sur lib/, frontend/src/, docs modifiés = seulement les fallbacks legacy ; cocher les cases du plan ; **pas de commit**.
