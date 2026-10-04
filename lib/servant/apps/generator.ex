defmodule Servant.Apps.Generator do
  @moduledoc """
  Builder agent: turns a plain-language description into an installed custom
  app (contract in docs/custom-apps.md). It uses a single chat completion and
  no tool use. Servant writes the manifest itself and the model only makes
  the entry module. As a result, the flow stays reliable with small local
  models.

  Servant tracks every action as a "builder" run in agent_runs (model, tokens,
  duration). The start_* variants run in a supervised Task. The callers poll
  the run.
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

  @doc """
  Synchronous create that the tests use. Returns
  `{:ok, app, run} | {:error, message, run}` when a run row exists. Returns
  `{:error, message}` (no run) when the validation fails before the creation of a
  run row (agents disabled, blank name/description, unusable slug).
  """
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

  @doc """
  Synchronous modify that the tests use. Returns
  `{:ok, app, run} | {:error, message, run}` when a run row exists. Returns
  `{:error, :not_found} | {:error, message}` (no run) when the validation fails
  before the creation of a run row (agents disabled, unknown or non-generated
  app, blank instruction).
  """
  def modify_now(user, app_id, instruction, ai_opts \\ []) do
    with {:ok, run, app} <- prepare_modify(user, app_id, instruction) do
      run_modify(run, user, app, instruction, ai_opts)
    end
  end

  @doc "Extracts the last fenced js block. The block must default-export the module."
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

  @doc "Returns the app id slug derived from the display name."
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
    case Agents.create_run(user.id, %{
           type: "builder",
           action: action,
           app_id: app_id,
           status: "running",
           model: config["model"],
           prompt: String.slice(prompt, 0, 2000)
         }) do
      {:ok, run} ->
        {:ok, run}

      # Defensive: config["model"] is validated as non-blank before the user can
      # enable the agents. As a result, this changeset never fails in normal
      # operation. Guard it anyway, so that a controller never gets a raw
      # %Ecto.Changeset{} to JSON-encode.
      {:error, %Ecto.Changeset{}} ->
        {:error, "could not create the run"}
    end
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

  # Chats (with one repair retry). Then it gives the module to `install` and
  # records the outcome on the run.
  defp execute(run, user, messages, ai_opts, install) do
    config = Accounts.ai_config(user)
    messages = [%{role: "system", content: @system_prompt} | messages]
    started = System.monotonic_time(:millisecond)

    try do
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
    rescue
      # Fail the run on an unexpected raise (a File.write! I/O error, a crash
      # inside install). If not, the run stays at "running" forever and the
      # frontend polls it endlessly. Then re-raise. As a result, the callers
      # (and the supervised Task, for start_generate/start_modify) still see
      # the crash.
      exception ->
        {:ok, _run} = Agents.fail_run(run, Exception.message(exception), nil, elapsed(started))
        reraise exception, __STACKTRACE__
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
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens
    }
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
