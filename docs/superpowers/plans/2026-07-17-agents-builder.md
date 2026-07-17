# Agents (base commune) + builder d'apps : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Livrer la base commune des agents IA (config chiffrée par user, client OpenAI-compatible, historique de runs) et l'agent builder v1 : générer / modifier / restaurer des custom apps depuis Settings, désactivé par défaut.

**Architecture:** Un client `Servant.AI` (un seul protocole, chat completions), un flux one-shot `Servant.Apps.Generator` (le modèle rend un bloc ```js, Servant fabrique le manifest et réutilise `Apps.install_from_dir` / `update_from_dir`), une table `agent_runs` pour le tracking manifesto (modèle, tokens, durée). Exécution en Task supervisée, le frontend poll le run.

**Tech Stack:** Elixir/Phoenix (Req, Ecto/SQLite, OpenApiSpex), Vue 3 `<script setup>` TS (SettingsView), pas de nouvelle dépendance.

**Spec:** `docs/superpowers/specs/2026-07-17-agents-design.md` (validée le 17/07).

## Global Constraints

- **Jamais de tiret cadratin** (em dash) nulle part : code, docs, copy UI, messages.
- **Pas de commit automatique** : Frank commite sur demande explicite. Chaque tâche se termine par une vérification (`mix test <fichier>`), jamais par `git commit`.
- HTTP via `Req` uniquement. Aucune nouvelle dépendance.
- Style Elixir : `@moduledoc` juste après `defmodule`, alias alphabétiques, pas de single-pipe, prédicats en `?`. Champs Ecto toujours `:string` même pour une colonne `:text`.
- Tests : `start_supervised!/1`, jamais `Process.sleep`, valeur réelle à gauche de l'opérateur.
- Migrations : `mix ecto.gen.migration <nom>` une par une ; **vérifier que les timestamps diffèrent** (collision vécue le 16/07 : deux `gen.migration` dans la même minute ont produit le même timestamp, le second écrase le premier).
- Copy UI en anglais, sobre (Sustainable AI Manifesto) : pas d'icône IA/étincelle, pas de nom d'assistant, le modèle utilisé est affiché sur les boutons d'action, limites annoncées.
- Fin de plan : `mix precommit` vert + `cd frontend && npm run build` + `npx prettier --write` sur les fichiers front touchés.

---

### Task 1: Config IA par utilisateur (`users.ai_config`)

**Files:**
- Create: migration `add_ai_config_to_users` (via `mix ecto.gen.migration`)
- Modify: `lib/servant/accounts/user.ex` (champ + changeset)
- Modify: `lib/servant/accounts.ex` (defaults, update, masque)
- Test: `test/servant/accounts_test.exs` (nouveau `describe "ai_config"`)

**Interfaces:**
- Produces: `Accounts.ai_config(user) :: map` (clés string `"enabled"`, `"base_url"`, `"model"`, `"api_key"`, defaults fusionnés), `Accounts.ai_enabled?(user) :: boolean`, `Accounts.update_ai_config(user, attrs) :: {:ok, user} | {:error, binary | changeset}`, `Accounts.masked_ai_config(user) :: map` (api_key remplacée par `"***"` ou nil).

- [ ] **Step 1: Écrire les tests qui échouent** dans `test/servant/accounts_test.exs` (même style que les describe existants du fichier ; `user_fixture()` vient de `test/support/fixtures.ex`) :

```elixir
  describe "ai_config" do
    test "defaults to disabled with the local base URL" do
      user = user_fixture()
      config = Accounts.ai_config(user)

      assert config["enabled"] == false
      assert config["base_url"] == "http://localhost:11434/v1"
      assert config["model"] == ""
      assert config["api_key"] == nil
      refute Accounts.ai_enabled?(user)
    end

    test "update_ai_config stores the config and ai_enabled? follows" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_ai_config(user, %{
          "enabled" => true,
          "model" => "qwen2.5-coder:14b",
          "api_key" => "sk-secret"
        })

      assert Accounts.ai_enabled?(user)
      assert Accounts.ai_config(user)["model"] == "qwen2.5-coder:14b"
      assert Accounts.ai_config(user)["api_key"] == "sk-secret"
    end

    test "keeps the stored key when given the mask, clears it on nil" do
      user = user_fixture()
      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret", "model" => "m"})

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "***", "model" => "m2"})
      assert Accounts.ai_config(user)["api_key"] == "sk-secret"
      assert Accounts.ai_config(user)["model"] == "m2"

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => nil})
      assert Accounts.ai_config(user)["api_key"] == nil
    end

    test "masked_ai_config hides the key" do
      user = user_fixture()
      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret"})

      assert Accounts.masked_ai_config(user)["api_key"] == "***"
      assert Accounts.masked_ai_config(user_fixture())["api_key"] == nil
    end

    test "rejects a non-http base_url and enabling without a model" do
      user = user_fixture()

      assert {:error, message} = Accounts.update_ai_config(user, %{"base_url" => "ftp://x"})
      assert message =~ "base_url"

      assert {:error, message} = Accounts.update_ai_config(user, %{"enabled" => true})
      assert message =~ "model"
    end
  end
```

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant/accounts_test.exs` doit échouer (fonctions inexistantes).

- [ ] **Step 3: Migration** : `mix ecto.gen.migration add_ai_config_to_users`, contenu :

```elixir
defmodule Servant.Repo.Migrations.AddAiConfigToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :ai_config, :binary
    end
  end
end
```

- [ ] **Step 4: Champ + changeset dans `lib/servant/accounts/user.ex`**. Dans le `schema`, après `field :enabled_apps, {:array, :string}` :

```elixir
    # AI agents config (enabled/base_url/model/api_key), encrypted at rest
    # like connector secrets
    field :ai_config, Servant.Encrypted.Map, redact: true
```

Et après `avatar_changeset/2` :

```elixir
  def ai_config_changeset(user, config) when is_map(config) do
    change(user, ai_config: config)
  end
```

- [ ] **Step 5: Fonctions dans `lib/servant/accounts.ex`** (près de `update_profile/2` ; la validation vit ici, le changeset ne fait que porter la map) :

```elixir
  @ai_defaults %{
    "enabled" => false,
    "base_url" => "http://localhost:11434/v1",
    "model" => "",
    "api_key" => nil
  }

  @doc "AI agents config with defaults merged in (string keys)."
  def ai_config(%User{} = user), do: Map.merge(@ai_defaults, user.ai_config || %{})

  def ai_enabled?(%User{} = user), do: ai_config(user)["enabled"] == true

  @doc "ai_config with the API key replaced by \"***\" (for API responses)."
  def masked_ai_config(%User{} = user) do
    config = ai_config(user)
    %{config | "api_key" => if(config["api_key"], do: "***", else: nil)}
  end

  @doc """
  Updates the AI config from user-supplied attrs. Unknown keys are ignored;
  an api_key of "***" keeps the stored one (that is what the API returns).
  """
  def update_ai_config(%User{} = user, attrs) when is_map(attrs) do
    current = ai_config(user)

    config = %{
      "enabled" => Map.get(attrs, "enabled", current["enabled"]) == true,
      "base_url" => attrs |> Map.get("base_url", current["base_url"]) |> to_string() |> String.trim(),
      "model" => attrs |> Map.get("model", current["model"]) |> to_string() |> String.trim(),
      "api_key" => resolve_api_key(Map.get(attrs, "api_key", :keep), current["api_key"])
    }

    cond do
      not String.starts_with?(config["base_url"], ["http://", "https://"]) ->
        {:error, "base_url must be an http(s) URL"}

      config["enabled"] and config["model"] == "" ->
        {:error, "model is required to enable agents"}

      true ->
        user |> User.ai_config_changeset(config) |> Repo.update()
    end
  end

  defp resolve_api_key(:keep, current), do: current
  defp resolve_api_key("***", current), do: current
  defp resolve_api_key(nil, _current), do: nil
  defp resolve_api_key("", _current), do: nil
  defp resolve_api_key(key, _current) when is_binary(key), do: key
```

- [ ] **Step 6: Vérifier** : `mix ecto.migrate` puis `mix test test/servant/accounts_test.exs` vert.

---

### Task 2: Client `Servant.AI` (OpenAI-compatible)

**Files:**
- Create: `lib/servant/ai.ex`
- Test: `test/servant/ai_test.exs`

**Interfaces:**
- Consumes: la map de config de Task 1 (clés string).
- Produces: `Servant.AI.chat(config, messages, opts \\ []) :: {:ok, %{content: binary, usage: %{input_tokens: integer, output_tokens: integer} | nil}} | {:error, binary}`. `messages` est une liste de `%{role: ..., content: ...}`. `opts` sont des options Req additionnelles (les tests y passent `plug:`).

- [ ] **Step 1: Écrire `test/servant/ai_test.exs`** (Req embarque `Req.Test` ; l'option `plug:` court-circuite le réseau) :

```elixir
defmodule Servant.AITest do
  use ExUnit.Case, async: true

  alias Servant.AI

  @config %{
    "base_url" => "http://localhost:9999/v1",
    "model" => "test-model",
    "api_key" => nil
  }

  @messages [%{role: "system", content: "s"}, %{role: "user", content: "u"}]

  test "posts to {base_url}/chat/completions and returns content and usage" do
    plug = fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["model"] == "test-model"
      assert payload["stream"] == false
      assert [%{"role" => "system"}, %{"role" => "user"}] = payload["messages"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "hello"}}],
        "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 34}
      })
    end

    assert {:ok, %{content: "hello", usage: usage}} = AI.chat(@config, @messages, plug: plug)
    assert usage == %{input_tokens: 12, output_tokens: 34}
  end

  test "sends a bearer header when a key is configured" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-x"]
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
    end

    config = Map.put(@config, "api_key", "sk-x")
    assert {:ok, %{content: "ok", usage: nil}} = AI.chat(config, @messages, plug: plug)
  end

  test "returns an error on a non-200 status" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

    assert {:error, message} = AI.chat(@config, @messages, plug: plug)
    assert message =~ "HTTP 500"
  end

  test "returns an error on an unexpected body" do
    plug = fn conn -> Req.Test.json(conn, %{"weird" => true}) end

    assert {:error, message} = AI.chat(@config, @messages, plug: plug)
    assert message =~ "unexpected response"
  end
end
```

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant/ai_test.exs` (module inexistant).

- [ ] **Step 3: Implémenter `lib/servant/ai.ex`** :

```elixir
defmodule Servant.AI do
  @moduledoc """
  Minimal client for OpenAI-compatible chat completion endpoints (Ollama,
  LM Studio, vLLM, Mistral, OpenAI, Anthropic's compatibility layer). One
  protocol, no per-vendor adapters: the user configures a base URL, a model
  and an optional API key in Settings > Agents.

  No SSRF guard on the base URL: pointing at localhost (a local Ollama) is
  the nominal case and the URL is the user's own deliberate configuration.
  """

  # Local models on CPU can take minutes to produce a full app module.
  @receive_timeout 300_000

  @doc """
  Sends `messages` to `{base_url}/chat/completions`. Returns
  `{:ok, %{content: binary, usage: usage}}` where `usage` is
  `%{input_tokens: n, output_tokens: n}` or nil when the server does not
  report it, or `{:error, message}`. `opts` are extra Req options (tests
  inject `plug:` stubs through them).
  """
  def chat(config, messages, opts \\ []) do
    url = String.trim_trailing(to_string(config["base_url"]), "/") <> "/chat/completions"

    request =
      [
        url: url,
        json: %{model: config["model"], messages: messages, stream: false},
        headers: auth_headers(config["api_key"]),
        receive_timeout: @receive_timeout,
        retry: false
      ] ++ opts

    case Req.post(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{excerpt(body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp auth_headers(key) when is_binary(key) and key != "", do: [{"authorization", "Bearer #{key}"}]
  defp auth_headers(_), do: []

  defp parse(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body)
       when is_binary(content) do
    {:ok, %{content: content, usage: usage(body["usage"])}}
  end

  defp parse(body), do: {:error, "unexpected response: #{excerpt(body)}"}

  defp usage(%{"prompt_tokens" => input, "completion_tokens" => output})
       when is_integer(input) and is_integer(output) do
    %{input_tokens: input, output_tokens: output}
  end

  defp usage(_), do: nil

  defp excerpt(body) when is_binary(body), do: String.slice(body, 0, 300)
  defp excerpt(body), do: body |> inspect() |> String.slice(0, 300)
end
```

- [ ] **Step 4: Vérifier** : `mix test test/servant/ai_test.exs` vert.

---

### Task 3: Historique des runs (`agent_runs`)

**Files:**
- Create: migration `create_agent_runs`
- Create: `lib/servant/agents/run.ex`
- Create: `lib/servant/agents.ex`
- Test: `test/servant/agents_test.exs`

**Interfaces:**
- Produces: `Agents.create_run(user_id, attrs) :: {:ok, run} | {:error, changeset}`, `Agents.get_run(user_id, id) :: run | nil` (id non-UUID toléré, renvoie nil), `Agents.list_runs(user_id, limit \\ 50)`, `Agents.complete_run(run, usage_or_nil, duration_ms)`, `Agents.fail_run(run, error, usage \\ nil, duration_ms \\ nil)`. `usage` a la forme de Task 2.

- [ ] **Step 1: Écrire `test/servant/agents_test.exs`** :

```elixir
defmodule Servant.AgentsTest do
  use Servant.DataCase

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
    _old = run_fixture(user.id, %{action: "create"})
    new = run_fixture(user.id, %{action: "modify"})
    _other = run_fixture(user_fixture().id)

    runs = Agents.list_runs(user.id)
    assert length(runs) == 2
    assert hd(runs).id == new.id
  end
end
```

Note : si `hd(runs).id == new.id` est instable (deux inserts dans la même seconde, timestamps `:utc_datetime`), ordonner par `[desc: :inserted_at, desc: :id]` ne suffit pas avec des binary_id aléatoires ; dans ce cas remplacer l'assertion par un simple contrôle de membership (`Enum.map(runs, & &1.id)` contient les deux). Choisir la variante stable au moment de l'implémentation.

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant/agents_test.exs`.

- [ ] **Step 3: Migration** : `mix ecto.gen.migration create_agent_runs` (timestamp différent de Task 1 !) :

```elixir
defmodule Servant.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :action, :string, null: false
      add :app_id, :string
      add :status, :string, null: false
      add :model, :string, null: false
      add :prompt, :text
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :duration_ms, :integer
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:user_id, :inserted_at])
  end
end
```

- [ ] **Step 4: Schéma `lib/servant/agents/run.ex`** :

```elixir
defmodule Servant.Agents.Run do
  @moduledoc """
  One AI agent run: which action ran, on which model, what it consumed
  (tokens, duration) and how it ended. v1 only has type "builder".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :type, :string
    field :action, :string
    field :app_id, :string
    field :status, :string, default: "running"
    field :model, :string
    field :prompt, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :duration_ms, :integer
    field :error, :string

    belongs_to :user, Servant.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :type,
      :action,
      :app_id,
      :status,
      :model,
      :prompt,
      :input_tokens,
      :output_tokens,
      :duration_ms,
      :error
    ])
    |> validate_required([:type, :action, :status, :model])
    |> validate_inclusion(:status, ~w(running ok error))
  end
end
```

- [ ] **Step 5: Contexte `lib/servant/agents.ex`** :

```elixir
defmodule Servant.Agents do
  @moduledoc """
  Shared bookkeeping for AI agent runs. Every run records the model used,
  the tokens consumed and its duration (Sustainable AI manifesto). v1 only
  ships the "builder" type; explorer and recurrent agents will reuse this.
  """

  import Ecto.Query

  alias Servant.Agents.Run
  alias Servant.Repo

  def create_run(user_id, attrs) do
    %Run{user_id: user_id}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run(user_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Run, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

  def list_runs(user_id, limit \\ 50) do
    Run
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def complete_run(run, usage, duration_ms) do
    update_run(run, %{
      status: "ok",
      input_tokens: usage && usage.input_tokens,
      output_tokens: usage && usage.output_tokens,
      duration_ms: duration_ms
    })
  end

  def fail_run(run, error, usage \\ nil, duration_ms \\ nil) do
    update_run(run, %{
      status: "error",
      error: error |> to_string() |> String.slice(0, 2000),
      input_tokens: usage && usage.input_tokens,
      output_tokens: usage && usage.output_tokens,
      duration_ms: duration_ms
    })
  end

  defp update_run(run, attrs) do
    run |> Run.changeset(attrs) |> Repo.update()
  end
end
```

- [ ] **Step 6: Vérifier** : `mix ecto.migrate` puis `mix test test/servant/agents_test.exs` vert.

---

### Task 4: Apps générées (repo_url nullable, `generated?`, restore)

**Files:**
- Create: migration `make_user_apps_repo_url_nullable`
- Modify: `lib/servant/apps/user_app.ex` (validate_required)
- Modify: `lib/servant/apps.ex` (helpers + restore_previous)
- Test: `test/servant/apps_test.exs` (nouveau describe ; **reprendre le setup FILES_DIR existant de ce fichier** pour les fixtures disque)

**Interfaces:**
- Consumes: `Apps.install_from_dir(user_id, dir, repo_url)` accepte désormais `nil` comme repo_url.
- Produces: `Apps.generated?(app) :: boolean`, `Apps.previous_version?(app) :: boolean`, `Apps.restore_previous(user_id, app_id) :: {:ok, app} | {:error, :not_found} | {:error, binary}`.

- [ ] **Step 1: Tests** dans `test/servant/apps_test.exs`. Helper local pour installer une app générée (réutiliser le pattern des tests existants du fichier qui fabriquent un dossier + manifest ; ne pas dupliquer si un helper existe déjà) :

```elixir
  defp install_generated(user_id, app_id, code) do
    dir = Path.join(System.tmp_dir!(), "gen-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.js"), code)

    manifest = %{"id" => app_id, "name" => "Gen App", "entry" => "index.js"}
    File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))

    {:ok, app} = Apps.install_from_dir(user_id, dir, nil)
    File.rm_rf!(dir)
    app
  end

  describe "generated apps" do
    test "install_from_dir accepts a nil repo_url and marks the app generated" do
      user = user_fixture()
      app = install_generated(user.id, "gen-todo", "export default {}")

      assert app.repo_url == nil
      assert Apps.generated?(app)
      refute Apps.previous_version?(app)
    end

    test "a git app is not generated" do
      # reprendre la fixture git existante du fichier (install_from_dir avec
      # un repo_url non nil) et vérifier :
      # refute Apps.generated?(app)
    end

    test "restore_previous swaps the entry with index.prev.js and bumps updated_at" do
      user = user_fixture()
      app = install_generated(user.id, "gen-todo", "// v2")

      dir = Apps.install_dir(user.id, "gen-todo")
      File.write!(Path.join(dir, "index.prev.js"), "// v1")

      assert Apps.previous_version?(app)
      {:ok, restored} = Apps.restore_previous(user.id, "gen-todo")

      assert File.read!(Path.join(dir, "index.js")) == "// v1"
      assert File.read!(Path.join(dir, "index.prev.js")) == "// v2"
      assert DateTime.compare(restored.updated_at, app.updated_at) in [:gt, :eq]
    end

    test "restore_previous without a previous version fails" do
      user = user_fixture()
      install_generated(user.id, "gen-todo", "// only")

      assert {:error, message} = Apps.restore_previous(user.id, "gen-todo")
      assert message =~ "previous"
    end

    test "restore_previous refuses git apps and unknown apps" do
      user = user_fixture()
      assert Apps.restore_previous(user.id, "nope") == {:error, :not_found}
      # avec la fixture git : {:error, message} et message =~ "generated"
    end
  end
```

Le commentaire "reprendre la fixture git existante" désigne le helper d'installation déjà présent dans `apps_test.exs` (celui qui passe un `repo_url` https) ; le lire et l'utiliser tel quel.

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant/apps_test.exs`.

- [ ] **Step 3: Migration** : `mix ecto.gen.migration make_user_apps_repo_url_nullable` :

```elixir
defmodule Servant.Repo.Migrations.MakeUserAppsRepoUrlNullable do
  use Ecto.Migration

  def change do
    alter table(:user_apps) do
      modify :repo_url, :string, null: true, from: {:string, null: false}
    end
  end
end
```

Note SQLite : si `modify` échoue sur exqlite (ALTER COLUMN limité), utiliser la stratégie table-recopie ou simplement vérifier ; exqlite/ecto_sqlite3 sait faire un `modify` par recréation de table. Tester avec `mix ecto.migrate` et `mix ecto.rollback --step 1` avant de continuer.

- [ ] **Step 4: `lib/servant/apps/user_app.ex`** : retirer `:repo_url` du `validate_required` :

```elixir
    |> validate_required([:app_id, :name, :entry])
```

- [ ] **Step 5: Helpers dans `lib/servant/apps.ex`** (après `entry_url/1`) :

```elixir
  @doc "True when the app was written by the builder agent (no git repo)."
  def generated?(%UserApp{repo_url: repo_url}), do: is_nil(repo_url)

  @doc "True when the app has a restorable previous version on disk."
  def previous_version?(%UserApp{} = app) do
    generated?(app) and
      File.regular?(Path.join(install_dir(app.user_id, app.app_id), "index.prev.js"))
  end

  @doc """
  Swaps a generated app's entry module with its saved previous version
  (`index.prev.js`) and bumps updated_at so the SPA reloads the module.
  """
  def restore_previous(user_id, app_id) do
    app = get_app(user_id, app_id)
    dir = install_dir(user_id, app_id)
    prev = Path.join(dir, "index.prev.js")

    cond do
      is_nil(app) ->
        {:error, :not_found}

      not generated?(app) ->
        {:error, "only generated apps have a restorable version"}

      not File.regular?(prev) ->
        {:error, "no previous version to restore"}

      true ->
        current = Path.join(dir, app.entry)
        swap = Path.join(dir, "index.swap.js")
        File.rename!(current, swap)
        File.rename!(prev, current)
        File.rename!(swap, prev)
        # force: true bumps updated_at even without changes (?v= cache busting)
        app |> UserApp.changeset(%{}) |> Repo.update(force: true)
    end
  end
```

- [ ] **Step 6: Vérifier** : `mix ecto.migrate` puis `mix test test/servant/apps_test.exs` vert.

---

### Task 5: `Servant.Apps.Generator` (le builder)

**Files:**
- Create: `lib/servant/apps/generator.ex`
- Modify: `lib/servant/application.ex` (Task.Supervisor)
- Test: `test/servant/apps/generator_test.exs`

**Interfaces:**
- Consumes: `Accounts.ai_config/1` + `ai_enabled?` (T1), `AI.chat/3` (T2), `Agents.*` (T3), `Apps.install_from_dir/update_from_dir/get_app/install_dir/generated?` (T4), `Storage.tmp_workspace/cleanup_tmp`.
- Produces: `Generator.start_generate(user, name, description) :: {:ok, run} | {:error, binary}`, `Generator.start_modify(user, app_id, instruction) :: {:ok, run} | {:error, :not_found} | {:error, binary}` (asynchrones, pour les contrôleurs), `Generator.generate_now/4` et `Generator.modify_now/4` (synchrones, `ai_opts` en dernier argument, pour les tests) qui renvoient `{:ok, app, run} | {:error, message, run}`, `Generator.extract_module(content)`, `Generator.slugify(name)`.

- [ ] **Step 1: Ajouter le Task.Supervisor** dans `lib/servant/application.ex`, après `Servant.Auth.Throttle,` :

```elixir
        # Builder agent generations run here (fire-and-forget, run row = status)
        {Task.Supervisor, name: Servant.Agents.TaskSupervisor},
```

- [ ] **Step 2: Écrire `test/servant/apps/generator_test.exs`** :

````elixir
defmodule Servant.Apps.GeneratorTest do
  use Servant.DataCase

  alias Servant.Accounts
  alias Servant.Apps
  alias Servant.Apps.Generator

  # Reprendre ici le setup FILES_DIR temporaire de test/servant/apps_test.exs
  # (même bloc setup) pour que install_dir pointe sur un dossier jetable.

  @valid_reply """
  Here is your app:

  ```js
  export default {
    mount(el, ctx) { el.textContent = 'hello' },
    unmount(el) {}
  }
  ```
  """

  defp user_with_agents do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_ai_config(user, %{
        "enabled" => true,
        "model" => "test-model",
        "base_url" => "http://localhost:9999/v1"
      })

    user
  end

  defp ai_reply(content) do
    fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => content}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20}
      })
    end
  end

  describe "generate_now/4" do
    test "installs the app and completes the run" do
      user = user_with_agents()

      assert {:ok, app, run} =
               Generator.generate_now(user, "My Todo", "track todos", plug: ai_reply(@valid_reply))

      assert app.app_id == "my-todo"
      assert app.repo_url == nil
      assert app.entry == "index.js"

      code = File.read!(Path.join(Apps.install_dir(user.id, "my-todo"), "index.js"))
      assert code =~ "export default"

      assert run.status == "ok"
      assert run.action == "create"
      assert run.model == "test-model"
      assert run.input_tokens == 10
      assert run.output_tokens == 20
      assert is_integer(run.duration_ms)
    end

    test "refuses when agents are disabled" do
      assert {:error, message} = Generator.generate_now(user_fixture(), "X", "y")
      assert message =~ "disabled"
    end

    test "refuses a blank name or description" do
      user = user_with_agents()
      assert {:error, _} = Generator.generate_now(user, "", "desc")
      assert {:error, _} = Generator.generate_now(user, "Name", " ")
      assert {:error, _} = Generator.generate_now(user, "!!!", "desc")
    end

    test "retries once on an invalid reply, then fails the run" do
      user = user_with_agents()
      counter = start_supervised!({Agent, fn -> 0 end})

      plug = fn conn ->
        Agent.update(counter, &(&1 + 1))
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "no code here"}}]})
      end

      assert {:error, message, run} = Generator.generate_now(user, "Todo", "todo app", plug: plug)
      assert message =~ "did not return a valid module"
      assert run.status == "error"
      assert Agent.get(counter, & &1) == 2
    end

    test "a reserved app name fails the run with the install error" do
      user = user_with_agents()

      assert {:error, message, run} =
               Generator.generate_now(user, "Settings", "x", plug: ai_reply(@valid_reply))

      assert message =~ "reserved"
      assert run.status == "error"
    end
  end

  describe "modify_now/4" do
    test "rewrites the module and keeps the previous version" do
      user = user_with_agents()

      {:ok, app, _run} =
        Generator.generate_now(user, "My Todo", "track todos", plug: ai_reply(@valid_reply))

      original = File.read!(Path.join(Apps.install_dir(user.id, app.app_id), "index.js"))

      new_reply = """
      ```js
      export default { mount(el) { el.textContent = 'v2' }, unmount(el) {} }
      ```
      """

      assert {:ok, app, run} =
               Generator.modify_now(user, "my-todo", "say v2", plug: ai_reply(new_reply))

      dir = Apps.install_dir(user.id, "my-todo")
      assert File.read!(Path.join(dir, "index.js")) =~ "v2"
      assert File.read!(Path.join(dir, "index.prev.js")) == original
      assert Apps.previous_version?(app)
      assert run.action == "modify"
    end

    test "refuses unknown and non-generated apps" do
      user = user_with_agents()
      assert Generator.modify_now(user, "nope", "x") == {:error, :not_found}
      # avec une app git (fixture de apps_test) : {:error, message} =~ "generated"
    end
  end

  describe "extract_module/1" do
    test "takes the last js block" do
      content = "```js\nconst a = 1\n```\ntext\n```js\nexport default {}\n```"
      assert {:ok, code} = Generator.extract_module(content)
      assert code =~ "export default"
      refute code =~ "const a"
    end

    test "rejects a reply without a block or without export default" do
      assert {:error, _} = Generator.extract_module("no code")
      assert {:error, _} = Generator.extract_module("```js\nconst x = 1\n```")
    end
  end

  test "slugify/1" do
    assert Generator.slugify("My Todo App!") == "my-todo-app"
    assert Generator.slugify("  éé  ") == ""
    assert Generator.slugify(nil) == ""
  end
end
````

- [ ] **Step 3: Vérifier l'échec** : `mix test test/servant/apps/generator_test.exs`.

- [ ] **Step 4: Implémenter `lib/servant/apps/generator.ex`** :

````elixir
defmodule Servant.Apps.Generator do
  @moduledoc """
  Builder agent: turns a plain-language description into an installed custom
  app (contract in docs/custom-apps.md) with a single chat completion, no
  tool use. Servant writes the manifest itself and the model only produces
  the entry module, so the flow stays reliable with small local models.

  Every action is tracked as a "builder" run in agent_runs (model, tokens,
  duration). start_* variants run in a supervised Task; callers poll the run.
  """

  alias Servant.Accounts
  alias Servant.Agents
  alias Servant.AI
  alias Servant.Apps
  alias Servant.Storage

  @task_supervisor Servant.Agents.TaskSupervisor

  @system_prompt """
  You write a single-file JavaScript app for Servant, a personal data hub.
  Reply with exactly one JavaScript code block (```js ... ```) and nothing
  else around it but plain text. The block must be a self-contained ES
  module with no imports, default-exporting:

    export default {
      mount(el, ctx) { /* build the UI inside el with plain DOM */ },
      unmount(el) { /* clear timers and listeners you added */ }
    }

  The ctx object provides:
  - ctx.api.entries.list(filters), .get(id), .create(attrs), .update(id, attrs),
    .delete(id), .aggregate(params). Entries are the universal data objects
    {id, kind, source, title, occurred_at, data}; create needs at least
    {kind, source, title}; occurred_at is an ISO datetime; data is a free
    JSON object. Use a kind specific to this app for its own data.
  - ctx.api.fetch(path, opts): authenticated fetch against the Servant API.
  - ctx.confirm.ask({title, message}) resolves to a boolean.
  - ctx.navigate(path): SPA navigation.

  Rules:
  - Plain DOM only. No frameworks, no imports, no external network calls,
    no localStorage.
  - Style via a <style> element you append to el, using the host CSS
    variables: var(--bg), var(--bg-surface), var(--text), var(--text-muted),
    var(--border), var(--primary), var(--radius). No hardcoded colors.
  - Keep it small and working: prefer fewer features that work.
  """

  @doc "Starts an async create run. Returns {:ok, run} or {:error, message}."
  def start_generate(user, name, description) do
    with {:ok, run, slug} <- prepare_generate(user, name, description) do
      start_task(fn -> run_create(run, user, slug, name, description, []) end)
      {:ok, run}
    end
  end

  @doc "Synchronous create, used by tests. Returns {:ok, app, run} | {:error, message, run}."
  def generate_now(user, name, description, ai_opts \\ []) do
    with {:ok, run, slug} <- prepare_generate(user, name, description) do
      run_create(run, user, slug, name, description, ai_opts)
    end
  end

  @doc "Starts an async modify run on a generated app."
  def start_modify(user, app_id, instruction) do
    with {:ok, run, app} <- prepare_modify(user, app_id, instruction) do
      start_task(fn -> run_modify(run, user, app, instruction, []) end)
      {:ok, run}
    end
  end

  @doc "Synchronous modify, used by tests."
  def modify_now(user, app_id, instruction, ai_opts \\ []) do
    with {:ok, run, app} <- prepare_modify(user, app_id, instruction) do
      run_modify(run, user, app, instruction, ai_opts)
    end
  end

  @doc "Extracts the last fenced js block; it must default-export the module."
  def extract_module(content) when is_binary(content) do
    case Regex.scan(~r/```(?:js|javascript)?\s*\n(.*?)```/s, content) do
      [] ->
        {:error, "no ```js code block found"}

      matches ->
        code = matches |> List.last() |> Enum.at(1) |> String.trim()

        if String.contains?(code, "export default") do
          {:ok, code <> "\n"}
        else
          {:error, "the module must default-export the app object"}
        end
    end
  end

  @doc "App id slug derived from the display name."
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  def slugify(_), do: ""

  # --- Preparation: validations + run row ---

  defp prepare_generate(user, name, description) do
    config = Accounts.ai_config(user)
    slug = slugify(name)

    cond do
      config["enabled"] != true ->
        {:error, "agents are disabled in Settings"}

      not present?(name) ->
        {:error, "name is required"}

      not present?(description) ->
        {:error, "description is required"}

      slug == "" ->
        {:error, "name must contain latin letters or digits"}

      true ->
        with {:ok, run} <- create_run(user, "create", slug, description, config) do
          {:ok, run, slug}
        end
    end
  end

  defp prepare_modify(user, app_id, instruction) do
    config = Accounts.ai_config(user)
    app = Apps.get_app(user.id, app_id)

    cond do
      config["enabled"] != true ->
        {:error, "agents are disabled in Settings"}

      is_nil(app) ->
        {:error, :not_found}

      not Apps.generated?(app) ->
        {:error, "only generated apps can be modified this way"}

      not present?(instruction) ->
        {:error, "instruction is required"}

      true ->
        with {:ok, run} <- create_run(user, "modify", app.app_id, instruction, config) do
          {:ok, run, app}
        end
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp create_run(user, action, app_id, prompt, config) do
    Agents.create_run(user.id, %{
      type: "builder",
      action: action,
      app_id: app_id,
      status: "running",
      model: config["model"],
      prompt: String.slice(prompt, 0, 2000)
    })
  end

  defp start_task(fun) do
    {:ok, _pid} = Task.Supervisor.start_child(@task_supervisor, fun)
  end

  # --- Execution ---

  defp run_create(run, user, slug, name, description, ai_opts) do
    user_msg = "App name: #{name}\n\nWhat the app must do:\n#{description}"

    execute(run, user, [%{role: "user", content: user_msg}], ai_opts, fn code ->
      manifest = %{
        "id" => slug,
        "name" => String.slice(name, 0, 60),
        "description" => String.slice(description, 0, 255),
        "icon" => "Puzzle",
        "entry" => "index.js"
      }

      in_workspace(user.id, fn dir ->
        File.write!(Path.join(dir, "index.js"), code)
        File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
        Apps.install_from_dir(user.id, dir, nil)
      end)
    end)
  end

  defp run_modify(run, user, app, instruction, ai_opts) do
    case File.read(Path.join(Apps.install_dir(user.id, app.app_id), app.entry)) do
      {:error, reason} ->
        {:ok, run} = Agents.fail_run(run, "cannot read the app's module: #{inspect(reason)}")
        {:error, run.error, run}

      {:ok, current} ->
        user_msg =
          "Here is the current module of the app \"#{app.name}\":\n\n```js\n#{current}\n```\n\n" <>
            "Modify it as follows and reply with the complete new module:\n#{instruction}"

        execute(run, user, [%{role: "user", content: user_msg}], ai_opts, fn code ->
          manifest = %{
            "id" => app.app_id,
            "name" => app.name,
            "description" => app.description,
            "icon" => app.icon,
            "entry" => app.entry
          }

          in_workspace(user.id, fn dir ->
            File.write!(Path.join(dir, app.entry), code)
            File.write!(Path.join(dir, "index.prev.js"), current)
            File.write!(Path.join(dir, "servant-app.json"), Jason.encode!(manifest))
            Apps.update_from_dir(app, dir)
          end)
        end)
    end
  end

  # Chat (with one repair retry), then hand the module to `install` and
  # record the outcome on the run.
  defp execute(run, user, messages, ai_opts, install) do
    config = Accounts.ai_config(user)
    messages = [%{role: "system", content: @system_prompt} | messages]
    started = System.monotonic_time(:millisecond)

    case generate_module(config, messages, ai_opts) do
      {:ok, code, usage} ->
        case install.(code) do
          {:ok, app} ->
            {:ok, run} = Agents.complete_run(run, usage, elapsed(started))
            {:ok, app, run}

          {:error, message} ->
            {:ok, run} = Agents.fail_run(run, message, usage, elapsed(started))
            {:error, message, run}
        end

      {:error, message, usage} ->
        {:ok, run} = Agents.fail_run(run, message, usage, elapsed(started))
        {:error, message, run}
    end
  end

  defp generate_module(config, messages, ai_opts) do
    case AI.chat(config, messages, ai_opts) do
      {:ok, %{content: content, usage: usage}} ->
        case extract_module(content) do
          {:ok, code} -> {:ok, code, usage}
          {:error, reason} -> retry_module(config, messages, content, reason, usage, ai_opts)
        end

      {:error, message} ->
        {:error, message, nil}
    end
  end

  defp retry_module(config, messages, previous, reason, usage, ai_opts) do
    retry =
      messages ++
        [
          %{role: "assistant", content: previous},
          %{
            role: "user",
            content:
              "Your answer was invalid: #{reason}. Reply again with exactly " <>
                "one ```js code block containing the complete module."
          }
        ]

    case AI.chat(config, retry, ai_opts) do
      {:ok, %{content: content, usage: usage2}} ->
        case extract_module(content) do
          {:ok, code} ->
            {:ok, code, add_usage(usage, usage2)}

          {:error, reason} ->
            {:error, "the model did not return a valid module: #{reason}",
             add_usage(usage, usage2)}
        end

      {:error, message} ->
        {:error, message, usage}
    end
  end

  defp add_usage(nil, usage), do: usage
  defp add_usage(usage, nil), do: usage

  defp add_usage(a, b) do
    %{input_tokens: a.input_tokens + b.input_tokens, output_tokens: a.output_tokens + b.output_tokens}
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp in_workspace(user_id, fun) do
    dir = Storage.tmp_workspace(user_id)

    try do
      fun.(dir)
    after
      Storage.cleanup_tmp(dir)
    end
  end
end
````

- [ ] **Step 5: Vérifier** : `mix test test/servant/apps/generator_test.exs` vert, puis `mix test test/servant` (rien de cassé ailleurs).

---

### Task 6: API (contrôleurs + routes)

**Files:**
- Create: `lib/servant_web/controllers/ai_config_controller.ex`
- Modify: `lib/servant_web/controllers/app_controller.ex` (plug de gating + 5 actions + installed_json)
- Modify: `lib/servant_web/router.ex`
- Test: `test/servant_web/controllers/ai_config_controller_test.exs`
- Test: `test/servant_web/controllers/app_controller_test.exs` (nouveau describe ; le fichier existe, reprendre son setup)

**Interfaces:**
- Consumes: T1 (Accounts.*), T3 (Agents.get_run/list_runs), T4 (Apps.restore_previous/previous_version?/generated?), T5 (Generator.start_generate/start_modify).
- Produces (JSON): `GET/PUT /api/ai_config` -> `{data: {enabled, base_url, model, api_key}}` (clé masquée) ; `POST /api/apps/generate` et `POST /api/apps/:id/modify` -> 202 `{data: run}` ; `GET /api/apps/runs[/:id]` -> run(s) ; `POST /api/apps/:id/restore` -> `{data: app}` ; `installed_json` gagne `generated` et `has_previous`. Run JSON: `{id, type, action, app_id, status, model, prompt, input_tokens, output_tokens, duration_ms, error, inserted_at}`.

- [ ] **Step 1: Tests.** `test/servant_web/controllers/ai_config_controller_test.exs` :

```elixir
defmodule ServantWeb.AiConfigControllerTest do
  use ServantWeb.ConnCase

  alias Servant.Accounts

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "GET returns the defaults with a nil key", %{conn: conn} do
    conn = get(conn, "/api/ai_config")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["enabled"] == false
    assert data["base_url"] == "http://localhost:11434/v1"
    assert data["api_key"] == nil
  end

  test "PUT updates the config and masks the key", %{conn: conn} do
    conn =
      put(conn, "/api/ai_config", %{
        "enabled" => true,
        "model" => "test-model",
        "api_key" => "sk-secret"
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["enabled"] == true
    assert data["api_key"] == "***"
  end

  test "PUT with the mask keeps the stored key", %{conn: conn, user: user} do
    {:ok, _} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret", "model" => "m"})

    conn = put(conn, "/api/ai_config", %{"api_key" => "***", "model" => "m2"})
    assert json_response(conn, 200)

    user = Accounts.get_user!(user.id)
    assert Accounts.ai_config(user)["api_key"] == "sk-secret"
    assert Accounts.ai_config(user)["model"] == "m2"
  end

  test "PUT rejects enabling without a model", %{conn: conn} do
    conn = put(conn, "/api/ai_config", %{"enabled" => true})
    assert %{"error" => _} = json_response(conn, 422)
  end

  test "401 without auth" do
    conn = get(build_conn(), "/api/ai_config")
    assert json_response(conn, 401)
  end
end
```

Dans `app_controller_test.exs`, ajouter :

```elixir
  describe "builder agent endpoints" do
    defp enable_agents(user) do
      {:ok, user} =
        Servant.Accounts.update_ai_config(user, %{
          "enabled" => true,
          "model" => "test-model",
          # port fermé: le task échoue vite, le run passe en "error"; on
          # n'asserte jamais sur ce statut final ici
          "base_url" => "http://localhost:9/v1"
        })

      user
    end

    test "403 on every agent route when agents are disabled", %{conn: conn} do
      assert conn |> post("/api/apps/generate", %{"name" => "X", "description" => "y"}) |> json_response(403)
      assert conn |> post("/api/apps/x/modify", %{"instruction" => "y"}) |> json_response(403)
      assert conn |> post("/api/apps/x/restore") |> json_response(403)
      assert conn |> get("/api/apps/runs") |> json_response(403)
    end

    test "generate returns 202 with a pollable run", %{conn: conn, user: user} do
      enable_agents(user)

      conn = post(conn, "/api/apps/generate", %{"name" => "My Todo", "description" => "todos"})
      assert %{"data" => %{"id" => run_id, "status" => "running"}} = json_response(conn, 202)

      conn = get(conn, "/api/apps/runs/#{run_id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["action"] == "create"
      assert data["model"] == "test-model"
      assert data["app_id"] == "my-todo"
    end

    test "generate rejects an invalid name", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/generate", %{"name" => "!!!", "description" => "y"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "modify 404s on an unknown app", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/nope/modify", %{"instruction" => "x"})
      assert json_response(conn, 404)
    end

    test "runs lists the user's runs", %{conn: conn, user: user} do
      enable_agents(user)
      post(conn, "/api/apps/generate", %{"name" => "A B", "description" => "d"})

      conn = get(conn, "/api/apps/runs")
      assert %{"data" => [run | _]} = json_response(conn, 200)
      assert run["type"] == "builder"
    end

    test "restore surfaces Apps errors", %{conn: conn, user: user} do
      enable_agents(user)
      conn = post(conn, "/api/apps/nope/restore")
      assert json_response(conn, 404)
    end
  end
```

Note sandbox : le Task spawné par generate écrit son échec en base après la réponse ; l'allowance passe par `$callers`. Si un `DBConnection.OwnershipError` sporadique apparaît dans les logs de test, ne pas s'en inquiéter (le run est fire-and-forget) ; si un test en devient flaky, ne pas asserter après la fin du run, jamais de sleep.

- [ ] **Step 2: Vérifier l'échec** : `mix test test/servant_web/controllers/ai_config_controller_test.exs test/servant_web/controllers/app_controller_test.exs`.

- [ ] **Step 3: `lib/servant_web/controllers/ai_config_controller.ex`** :

```elixir
defmodule ServantWeb.AiConfigController do
  @moduledoc "Per-user AI agents configuration (Settings > Agents)."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema
  alias Servant.Accounts
  alias ServantWeb.Schemas

  tags(["agents"])

  @config_schema %Schema{
    type: :object,
    properties: %{
      enabled: %Schema{type: :boolean},
      base_url: %Schema{type: :string, description: "OpenAI-compatible base URL"},
      model: %Schema{type: :string},
      api_key: %Schema{type: :string, nullable: true, description: "masked as *** in responses"}
    }
  }

  operation(:show,
    summary: "AI agents configuration",
    description: "Session-only. The API key is masked.",
    responses: [
      ok: {"Config", "application/json", @config_schema},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    json(conn, %{data: Accounts.masked_ai_config(conn.assigns.current_user)})
  end

  operation(:update,
    summary: "Update the AI agents configuration",
    description: "Session-only. Send api_key \"***\" to keep the stored key.",
    request_body: {"Config", "application/json", @config_schema},
    responses: [
      ok: {"Config", "application/json", @config_schema},
      unprocessable_entity: {"Invalid config", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def update(conn, params) do
    case Accounts.update_ai_config(conn.assigns.current_user, params) do
      {:ok, user} ->
        json(conn, %{data: Accounts.masked_ai_config(user)})

      {:error, message} when is_binary(message) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid configuration"})
    end
  end
end
```

- [ ] **Step 4: AppController.** Ajouter les alias (`Servant.Accounts`, `Servant.Agents`, `Servant.Apps.Generator`, ordre alphabétique avec les existants), le plug sous les `tags` :

```elixir
  plug :require_agents when action in [:generate, :modify, :restore, :runs, :run]
```

Les actions (après `delete/2`, avant `installed_json/1`) et le plug + run_json en bas :

```elixir
  operation(:generate,
    summary: "Generate an app from a description (builder agent)",
    description:
      "Session-only; requires agents enabled in Settings. Starts an async " <>
        "run on the configured model server and returns it for polling. Only " <>
        "the name and description are sent to the model, never personal data.",
    request_body:
      {"Generation request", "application/json",
       %Schema{
         type: :object,
         properties: %{name: %Schema{type: :string}, description: %Schema{type: :string}},
         required: [:name, :description]
       }},
    responses: [
      accepted: {"Run", "application/json", %Schema{type: :object}},
      unprocessable_entity: {"Invalid request", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def generate(conn, params) do
    user = conn.assigns.current_user

    case Generator.start_generate(user, params["name"], params["description"]) do
      {:ok, run} ->
        conn |> put_status(:accepted) |> json(%{data: run_json(run)})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:modify,
    summary: "Modify a generated app (builder agent)",
    description:
      "Session-only; requires agents enabled. Sends the app's current module " <>
        "and the instruction to the model; the previous version is kept.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Modification request", "application/json",
       %Schema{
         type: :object,
         properties: %{instruction: %Schema{type: :string}},
         required: [:instruction]
       }},
    responses: [
      accepted: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid request", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def modify(conn, %{"id" => app_id} = params) do
    case Generator.start_modify(conn.assigns.current_user, app_id, params["instruction"]) do
      {:ok, run} ->
        conn |> put_status(:accepted) |> json(%{data: run_json(run)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "App not found"})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:restore,
    summary: "Restore a generated app's previous version",
    description: "Session-only; requires agents enabled. Swaps the module with index.prev.js.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Restored app", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"No previous version", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def restore(conn, %{"id" => app_id}) do
    case Apps.restore_previous(conn.assigns.current_user.id, app_id) do
      {:ok, app} ->
        json(conn, %{data: installed_json(app)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "App not found"})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  operation(:runs,
    summary: "List agent runs (model, tokens, duration)",
    description: "Session-only; requires agents enabled. Newest first, 50 max.",
    responses: [
      ok: {"Runs", "application/json", %Schema{type: :object}},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def runs(conn, _params) do
    runs = Agents.list_runs(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(runs, &run_json/1)})
  end

  operation(:run,
    summary: "Get one agent run (for polling)",
    description: "Session-only; requires agents enabled.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def run(conn, %{"id" => id}) do
    case Agents.get_run(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Run not found"})
      run -> json(conn, %{data: run_json(run)})
    end
  end

  defp require_agents(conn, _opts) do
    if Accounts.ai_enabled?(conn.assigns.current_user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "AI agents are disabled in Settings"})
      |> halt()
    end
  end

  defp run_json(run) do
    %{
      id: run.id,
      type: run.type,
      action: run.action,
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
```

Dans `installed_json/1`, ajouter les deux clés :

```elixir
      generated: is_nil(app.repo_url),
      has_previous: Apps.previous_version?(app),
```

- [ ] **Step 5: Routes** dans le scope `session_only` de `lib/servant_web/router.ex`, juste après `delete "/apps/:id", AppController, :delete` :

```elixir
        post "/apps/generate", AppController, :generate
        get "/apps/runs", AppController, :runs
        get "/apps/runs/:id", AppController, :run
        post "/apps/:id/modify", AppController, :modify
        post "/apps/:id/restore", AppController, :restore

        get "/ai_config", AiConfigController, :show
        put "/ai_config", AiConfigController, :update
```

- [ ] **Step 6: Vérifier** : `mix test test/servant_web/controllers/ai_config_controller_test.exs test/servant_web/controllers/app_controller_test.exs` vert, puis `mix test` complet.

---

### Task 7: Frontend, store et types

**Files:**
- Modify: `frontend/src/types.ts` (AiConfig, AgentRun)
- Modify: `frontend/src/stores/apps.ts` (champs + generate/modify/restore)

**Interfaces:**
- Consumes: les endpoints de Task 6.
- Produces: types `AiConfig`, `AgentRun` exportés de `types.ts` ; store `apps.generate(name, description) :: Promise<string>` (run id), `apps.modify(id, instruction) :: Promise<string>`, `apps.restore(id) :: Promise<void>` ; `InstalledApp` gagne `repo_url: string | null`, `generated: boolean`, `has_previous: boolean`.

- [ ] **Step 1: `frontend/src/types.ts`**, ajouter :

```ts
export interface AiConfig {
  enabled: boolean
  base_url: string
  model: string
  api_key: string | null
}

export interface AgentRun {
  id: string
  type: string
  action: string
  app_id: string | null
  status: 'running' | 'ok' | 'error'
  model: string
  prompt: string | null
  input_tokens: number | null
  output_tokens: number | null
  duration_ms: number | null
  error: string | null
  inserted_at: string
}
```

- [ ] **Step 2: `frontend/src/stores/apps.ts`.** Dans `InstalledApp` : `repo_url: string | null` et ajouter `generated: boolean` et `has_previous: boolean`. Ajouter avant le `return` :

```ts
  async function generate(name: string, description: string) {
    const res = await apiJson<{ data: { id: string } }>('POST', '/api/apps/generate', {
      body: { name, description }
    })
    return res.data.id
  }

  async function modify(id: string, instruction: string) {
    const res = await apiJson<{ data: { id: string } }>('POST', `/api/apps/${id}/modify`, {
      body: { instruction }
    })
    return res.data.id
  }

  async function restore(id: string) {
    await apiJson('POST', `/api/apps/${id}/restore`)
    await load(true)
  }
```

Et les exposer : `return { installed, loaded, defs, getDef, load, install, update, uninstall, generate, modify, restore }`.

- [ ] **Step 3: Vérifier** : `cd frontend && npm run build` (type-check) passe encore.

---

### Task 8: Frontend, SettingsView (carte Agents + génération)

**Files:**
- Modify: `frontend/src/views/SettingsView.vue`

**Interfaces:**
- Consumes: Task 7 (types + store), `useConfirm().ask`, `useApi()`, `formatDate`.

Copy manifesto : sobre, dit ce que ça fait, modèle affiché sur les boutons, limites annoncées, confirmation à l'activation, pas d'icône IA (utiliser `Wrench`).

- [ ] **Step 1: Script.** Ajouter aux imports lucide `Wrench, Pencil, Undo2`, et aux types `import type { ApiToken, AiConfig, AgentRun } from '../types'`. Ajouter après le bloc "Installed apps" :

```ts
// ----- Agents (model server config + run history) -----

const aiConfig = ref<AiConfig>({
  enabled: false,
  base_url: '',
  model: '',
  api_key: null
})
const aiSaving = ref(false)
const aiError = ref('')
const agentRuns = ref<AgentRun[]>([])

async function loadAiConfig() {
  try {
    aiConfig.value = (await api.get<{ data: AiConfig }>('/api/ai_config')).data
    if (aiConfig.value.enabled) await loadAgentRuns()
  } catch {
    // section shows defaults; not fatal for the rest of settings
  }
}

async function loadAgentRuns() {
  try {
    agentRuns.value = (await api.get<{ data: AgentRun[] }>('/api/apps/runs')).data
  } catch {
    agentRuns.value = []
  }
}

async function saveAiConfig(overrides: Partial<AiConfig> = {}) {
  aiError.value = ''
  aiSaving.value = true
  try {
    const body = { ...aiConfig.value, ...overrides }
    aiConfig.value = (await api.put<{ data: AiConfig }>('/api/ai_config', body)).data
    if (aiConfig.value.enabled) await loadAgentRuns()
  } catch (e) {
    aiError.value = e instanceof Error ? e.message : 'Save failed'
  } finally {
    aiSaving.value = false
  }
}

async function toggleAgents() {
  if (!aiConfig.value.enabled) {
    const ok = await ask({
      title: 'Enable agents',
      message:
        'App generation requests will be sent to the model server configured ' +
        'below. Only your app descriptions are sent, never your data. ' +
        'Generated code can be incorrect: review an app before trusting it.',
      confirmLabel: 'Enable'
    })
    if (!ok) return
    await saveAiConfig({ enabled: true })
  } else {
    await saveAiConfig({ enabled: false })
  }
}

// ----- App generation (builder agent) -----

const genName = ref('')
const genDescription = ref('')
const genBusy = ref(false)
const genError = ref('')
const modifyingId = ref('')
const modifyInstruction = ref('')
const restoringId = ref('')

async function pollRun(id: string): Promise<AgentRun> {
  for (;;) {
    const run = (await api.get<{ data: AgentRun }>(`/api/apps/runs/${id}`)).data
    if (run.status !== 'running') return run
    await new Promise(resolve => setTimeout(resolve, 2000))
  }
}

async function generateApp() {
  genError.value = ''
  genBusy.value = true
  try {
    const runId = await apps.generate(genName.value.trim(), genDescription.value.trim())
    const run = await pollRun(runId)
    if (run.status === 'ok') {
      genName.value = ''
      genDescription.value = ''
      await apps.load(true)
    } else {
      genError.value = run.error || 'Generation failed'
    }
    await loadAgentRuns()
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Generation failed'
  } finally {
    genBusy.value = false
  }
}

async function modifyApp(id: string) {
  genError.value = ''
  genBusy.value = true
  try {
    const runId = await apps.modify(id, modifyInstruction.value.trim())
    const run = await pollRun(runId)
    if (run.status === 'ok') {
      modifyingId.value = ''
      modifyInstruction.value = ''
      await apps.load(true)
    } else {
      genError.value = run.error || 'Modification failed'
    }
    await loadAgentRuns()
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Modification failed'
  } finally {
    genBusy.value = false
  }
}

async function restoreApp(id: string) {
  genError.value = ''
  restoringId.value = id
  try {
    await apps.restore(id)
  } catch (e) {
    genError.value = e instanceof Error ? e.message : 'Restore failed'
  } finally {
    restoringId.value = ''
  }
}
```

Dans `onMounted`, ajouter `loadAiConfig()`.

- [ ] **Step 2: Template, carte Agents** entre la carte Apps et la carte Export :

```html
    <!-- Agents -->
    <section class="card">
      <div class="card-header">
        <Wrench :size="20" class="card-icon" />
        <h2>Agents</h2>
      </div>
      <div class="card-body">
        <p class="tk-hint">
          Agents call a language model server that you configure (a local
          Ollama by default). Each run records the model used and the tokens
          consumed. Generated code can be incorrect: review an app before
          trusting it with your data.
        </p>

        <label class="tk-binary">
          <span class="tk-domain-label">Enable agents</span>
          <span class="tk-binary-box">
            <input
              type="checkbox"
              :checked="aiConfig.enabled"
              :disabled="aiSaving"
              @change="toggleAgents"
            />
          </span>
        </label>

        <template v-if="aiConfig.enabled">
          <form class="ai-form" @submit.prevent="saveAiConfig()">
            <label class="tk-expiry">
              <span class="tk-domain-label">Base URL</span>
              <input
                v-model="aiConfig.base_url"
                type="text"
                placeholder="http://localhost:11434/v1"
              />
            </label>
            <label class="tk-expiry">
              <span class="tk-domain-label">Model</span>
              <input
                v-model="aiConfig.model"
                type="text"
                placeholder="qwen2.5-coder:14b"
              />
            </label>
            <label class="tk-expiry">
              <span class="tk-domain-label">API key (optional)</span>
              <input
                v-model="aiConfig.api_key"
                type="password"
                placeholder="not needed for local servers"
              />
            </label>
            <div class="card-actions">
              <button type="submit" :disabled="aiSaving">
                {{ aiSaving ? 'Saving...' : 'Save' }}
              </button>
            </div>
          </form>

          <h3 class="app-subhead">Runs</h3>
          <table v-if="agentRuns.length" class="tk-table">
            <thead>
              <tr>
                <th>Date</th>
                <th>Action</th>
                <th>App</th>
                <th>Model</th>
                <th>Tokens</th>
                <th>Duration</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in agentRuns" :key="r.id">
                <td>{{ formatDate(r.inserted_at) }}</td>
                <td>{{ r.action }}</td>
                <td>{{ r.app_id || '-' }}</td>
                <td>{{ r.model }}</td>
                <td>
                  {{
                    r.input_tokens != null
                      ? `${r.input_tokens} in / ${r.output_tokens} out`
                      : '-'
                  }}
                </td>
                <td>
                  {{
                    r.duration_ms != null
                      ? `${Math.round(r.duration_ms / 1000)}s`
                      : '-'
                  }}
                </td>
                <td :title="r.error || ''">{{ r.status }}</td>
              </tr>
            </tbody>
          </table>
          <p v-else class="tk-empty">No runs yet.</p>
        </template>

        <p v-if="aiError" class="msg msg-error">{{ aiError }}</p>
      </div>
    </section>
```

- [ ] **Step 3: Template, carte Apps.** Le tableau des installed apps devient (remplace le `<tr v-for>` existant ; la colonne Repository affiche "generated" pour les apps sans repo, le bouton update git n'apparaît que pour les apps git, les boutons modify/restore que pour les générées) :

```html
          <tbody>
            <template v-for="a in apps.installed" :key="a.id">
              <tr>
                <td>{{ a.name }}</td>
                <td class="app-repo">{{ a.repo_url || 'generated' }}</td>
                <td class="app-actions">
                  <button
                    v-if="a.repo_url"
                    type="button"
                    class="tk-revoke"
                    title="Update from the repository"
                    :disabled="appUpdating === a.id"
                    @click="updateApp(a.id)"
                  >
                    <RefreshCw
                      :size="14"
                      :class="{ spin: appUpdating === a.id }"
                    />
                  </button>
                  <button
                    v-if="a.generated && aiConfig.enabled"
                    type="button"
                    class="tk-revoke"
                    title="Modify with the configured model"
                    :disabled="genBusy"
                    @click="modifyingId = modifyingId === a.id ? '' : a.id"
                  >
                    <Pencil :size="14" />
                  </button>
                  <button
                    v-if="a.generated && a.has_previous && aiConfig.enabled"
                    type="button"
                    class="tk-revoke"
                    title="Restore the previous version"
                    :disabled="restoringId === a.id"
                    @click="restoreApp(a.id)"
                  >
                    <Undo2 :size="14" />
                  </button>
                  <button
                    type="button"
                    class="tk-revoke"
                    title="Uninstall"
                    @click="uninstallApp(a.id, a.name)"
                  >
                    <Trash2 :size="14" />
                  </button>
                </td>
              </tr>
              <tr v-if="modifyingId === a.id">
                <td colspan="3">
                  <form class="app-form" @submit.prevent="modifyApp(a.id)">
                    <textarea
                      v-model="modifyInstruction"
                      rows="3"
                      placeholder="Describe the change"
                    ></textarea>
                    <div class="card-actions">
                      <button
                        type="submit"
                        :disabled="genBusy || !modifyInstruction.trim()"
                      >
                        {{
                          genBusy
                            ? `Running on ${aiConfig.model}...`
                            : `Modify (runs on ${aiConfig.model})`
                        }}
                      </button>
                    </div>
                  </form>
                </td>
              </tr>
            </template>
          </tbody>
```

Après le formulaire d'install git existant, ajouter le formulaire de génération :

```html
        <template v-if="aiConfig.enabled">
          <h3 class="app-subhead">Generate an app</h3>
          <p class="tk-hint">
            Describe the app; the configured model writes it and it installs
            like any other app. Review it before trusting it with your data.
          </p>
          <form class="app-form" @submit.prevent="generateApp">
            <input v-model="genName" type="text" placeholder="App name" />
            <textarea
              v-model="genDescription"
              rows="3"
              placeholder="What should the app do?"
            ></textarea>
            <p v-if="genError" class="msg msg-error">{{ genError }}</p>
            <div class="card-actions">
              <button
                type="submit"
                :disabled="genBusy || !genName.trim() || !genDescription.trim()"
              >
                {{
                  genBusy
                    ? `Generating with ${aiConfig.model}...`
                    : `Generate (runs on ${aiConfig.model})`
                }}
              </button>
            </div>
          </form>
        </template>
```

- [ ] **Step 4: CSS** (dans le `<style scoped>`, près de `.app-form input[type='url']`) :

```css
.app-form input[type='text'],
.app-form textarea {
  width: 100%;
  margin-bottom: 0.75rem;
}
.ai-form {
  margin-bottom: 1.5rem;
}
```

- [ ] **Step 5: Vérifier** : `cd frontend && npm run build` (type-check + build) vert, `npx vitest run` vert, puis `npx prettier --write src/views/SettingsView.vue src/stores/apps.ts src/types.ts`.

---

### Task 9: Docs + vérification finale

**Files:**
- Modify: `docs/custom-apps.md` (section apps générées)
- Modify: `DEVELOPMENT.md` (bullet architecture)

- [ ] **Step 1: `docs/custom-apps.md`**, ajouter en fin de fichier :

```markdown
## Generated apps (builder agent)

When agents are enabled (Settings > Agents, off by default), Servant can also
write an app for you: Settings > Apps > "Generate an app" sends your
description to the model server you configured (any OpenAI-compatible
endpoint; a local Ollama by default) and installs the produced module through
the same rail as git apps: same manifest validation, same /files serving,
same session privileges.

- Generated apps have no repository. They can be modified (a new instruction
  rewrites the module; the previous version is kept as `index.prev.js`) and
  restored (swap back to that previous version) from Settings > Apps.
- The model only receives your app name, your description and, on modify,
  the app's current source: never your personal data.
- Every run is recorded with its model, token usage and duration in
  Settings > Agents.
- Generated code can be incorrect: review an app before trusting it with
  your data.
```

- [ ] **Step 2: `DEVELOPMENT.md`**, dans "Architecture notes", après le bullet **Connectors** :

```markdown
- **Agents** share one per-user AI config (`users.ai_config`, encrypted) and one `agent_runs` history (model, tokens, duration per run). v1 ships the "builder" type only: `Servant.Apps.Generator` turns a description into an installed custom app via a single OpenAI-compatible chat completion (`Servant.AI`). Disabled by default (Settings > Agents).
```

- [ ] **Step 3: Vérification finale** :
- `mix precommit` (compile --warnings-as-errors, deps.audit, format, tests) vert.
- `cd frontend && npm run build` et `npx vitest run` verts.
- `rtk proxy grep -rn "—" lib/ frontend/src/ docs/custom-apps.md DEVELOPMENT.md` ne montre que les fallbacks legacy connus (parsing " — " pré-juillet 2026), aucun nouveau tiret cadratin.
- Cocher les cases de ce plan au fur et à mesure ; **pas de commit** (Frank commitera).
