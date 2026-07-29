defmodule Servant.Agents do
  @moduledoc """
  Shared bookkeeping for AI agent runs. Every run records the model used,
  the tokens consumed and its duration (Sustainable AI manifesto). Two
  recurrent modes ship: prompt reports (model-driven) and deterministic
  recipes (local aggregation). v1 also ships the "builder" type.
  """

  import Ecto.Query

  alias Servant.Accounts
  alias Servant.Agents.Agent
  alias Servant.Agents.Recipe
  alias Servant.Agents.Run
  alias Servant.AI
  alias Servant.Data
  alias Servant.Repo

  @intervals %{"every_hour" => 3600, "every_day" => 86_400, "every_week" => 604_800}

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

  @recipe_system_prompt """
  You translate a plain-language description of a recurring data script
  into a JSON recipe. Reply with a single JSON object only: no code
  fence, no prose.

  Recipe shape (every key optional):
  - "where": array of {"field", "op", "value"} conditions, AND semantics.
    Ops: eq, neq, contains, gt, gte, lt, lte, exists (exists takes no
    value). Fields: "title", "source", "occurred_at", "data.<key>",
    "metadata.<key>".
  - "group_by": a field path, or "day" | "week" | "month" (buckets on the
    entry date).
  - "aggregate": {"op": one of sum avg count min max last, "field": a
    field path}. count takes no field. Omit aggregate to list the entries
    instead.
  - "emit_if": {"op": one of eq neq gt gte lt lte, "value": a number}.
    Only valid with an aggregate and without group_by: the report is only
    produced when the aggregated value matches.
  """

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

  def create_run(user_id, attrs) do
    {agent_id, attrs} = Map.pop(attrs, :agent_id)

    %Run{user_id: user_id, agent_id: agent_id}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run(user_id, id) do
    sweep_stale_runs(user_id)

    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get_by(Run, id: uuid, user_id: user_id)
      :error -> nil
    end
  end

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

  defp sweep_stale_runs(user_id) do
    # Tasks do not survive a server restart, so a run still "running" past
    # this point was interrupted, not actually running; 30 min is far beyond
    # the 300s AI timeout plus retry.
    stale_cutoff = DateTime.add(DateTime.utc_now(), -30, :minute)

    Run
    |> where(user_id: ^user_id)
    |> where(status: "running")
    |> where([r], r.inserted_at < ^stale_cutoff)
    |> Repo.update_all(set: [status: "error", error: "interrupted"])
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

  @doc """
  Runs a recurring agent synchronously (tests and the scheduler): gathers
  the entries context, asks the model for a report, stores it as an
  ai_report entry. Returns {:ok, entry, run} | {:error, message, run};
  pre-run validation failures return {:error, message} without a run.
  """
  def run_now(user, agent, ai_opts \\ []) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      case agent.mode do
        "recipe" -> execute_recipe(run, user, agent)
        _mode -> execute_report(run, user, agent, ai_opts)
      end
    end
  end

  @doc "Async variant for the API: returns the run immediately, work happens in a supervised Task."
  def start_run(user, agent) do
    with {:ok, run, agent} <- prepare_run(user, agent) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Servant.Agents.TaskSupervisor, fn ->
          case agent.mode do
            "recipe" -> execute_recipe(run, user, agent)
            _mode -> execute_report(run, user, agent, [])
          end
        end)

      {:ok, run}
    end
  end

  @doc "Runs every due enabled agent sequentially; each agent is rescued individually."
  def run_due(now \\ DateTime.utc_now()) do
    for agent <- due_agents(now) do
      user = Accounts.get_user(agent.user_id)

      if user && Accounts.ai_enabled?(user) do
        try do
          run_now(user, agent)
        rescue
          # the run row was already failed by the execute rescue (report or recipe)
          _exception -> :error
        end
      end
    end

    :ok
  end

  @doc """
  Asks the configured model to translate a plain-language description
  into a recipe (authoring time only; execution never calls the model).
  The prompt carries entry kinds and data key names, never values. One
  repair round on an invalid reply. Every draft is a tracked run.
  """
  def draft_recipe(user, description, kinds, ai_opts \\ []) do
    config = Accounts.ai_config(user)

    cond do
      config["enabled"] != true ->
        {:error, "agents are disabled in Settings"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "description is required"}

      true ->
        do_draft(user, config, description, List.wrap(kinds), ai_opts)
    end
  end

  defp do_draft(user, config, description, kinds, ai_opts) do
    {:ok, run} =
      create_run(user.id, %{
        type: "recurrent",
        action: "draft_recipe",
        status: "running",
        model: config["model"],
        prompt: String.slice(description, 0, 2000)
      })

    started = System.monotonic_time(:millisecond)

    try do
      messages = [
        %{role: "system", content: @recipe_system_prompt},
        %{role: "user", content: draft_request(user.id, description, kinds)}
      ]

      case AI.chat(config, messages, ai_opts) do
        {:ok, %{content: content, usage: usage}} ->
          case parse_recipe(content) do
            {:ok, recipe} ->
              {:ok, run} = complete_run(run, usage, elapsed(started))
              {:ok, recipe, run}

            {:error, message} ->
              repair_draft(run, config, messages, content, message, usage, started, ai_opts)
          end

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

  defp repair_draft(run, config, messages, previous, message, usage, started, ai_opts) do
    messages =
      messages ++
        [
          %{role: "assistant", content: previous},
          %{
            role: "user",
            content:
              "That recipe is invalid: #{message}. Reply with a corrected JSON object only."
          }
        ]

    case AI.chat(config, messages, ai_opts) do
      {:ok, %{content: content, usage: usage2}} ->
        total = add_usage(usage, usage2)

        case parse_recipe(content) do
          {:ok, recipe} ->
            {:ok, run} = complete_run(run, total, elapsed(started))
            {:ok, recipe, run}

          {:error, message2} ->
            {:ok, run} = fail_run(run, message2, total, elapsed(started))
            {:error, message2, run}
        end

      {:error, message2} ->
        {:ok, run} = fail_run(run, message2, usage, elapsed(started))
        {:error, message2, run}
    end
  end

  defp parse_recipe(content) do
    json =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, content) do
        [_, fenced] -> fenced
        nil -> String.trim(content)
      end

    case Jason.decode(json) do
      {:ok, recipe} when is_map(recipe) ->
        case Recipe.validate(recipe) do
          :ok -> {:ok, recipe}
          {:error, _} = error -> error
        end

      {:ok, _other} ->
        {:error, "the reply must be a JSON object"}

      {:error, _} ->
        {:error, "the reply is not valid JSON"}
    end
  end

  defp draft_request(user_id, description, kinds) do
    keys = sample_keys(user_id, kinds)
    keys_line = if keys == [], do: "(none found)", else: Enum.join(keys, ", ")

    "Script: #{description}\n\n" <>
      "Entry kinds: #{Enum.join(kinds, ", ")}\n" <>
      "Known data fields (from recent entries, names only): #{keys_line}"
  end

  # Key names only: the draft never needs personal values.
  defp sample_keys(user_id, kinds) do
    user_id
    |> Data.list_entries(%{"kinds" => kinds, "per_page" => 20})
    |> Enum.flat_map(fn entry ->
      entry.data |> Map.keys() |> Enum.map(&"data.#{&1}")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_usage(nil, usage), do: usage
  defp add_usage(usage, nil), do: usage

  defp add_usage(a, b) do
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens
    }
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
            model: if(agent.mode == "recipe", do: nil, else: config["model"]),
            prompt: agent.prompt && String.slice(agent.prompt, 0, 2000)
          })

        case result do
          {:ok, run} -> {:ok, run, agent}
          {:error, %Ecto.Changeset{}} -> {:error, "could not create the run"}
        end
    end
  end

  defp execute_report(run, user, agent, ai_opts) do
    config = agent_config(user, agent)
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

  # One AI config per user (base URL, key, model); an agent may override the
  # model alone, e.g. a cheap local model for a daily digest and a stronger
  # one for a weekly analysis, without a second endpoint to configure.
  defp agent_config(user, agent) do
    config = Accounts.ai_config(user)

    case agent.model do
      nil -> config
      model -> Map.put(config, "model", model)
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

  defp execute_recipe(run, user, agent) do
    started = System.monotonic_time(:millisecond)

    try do
      from_dt = DateTime.add(DateTime.utc_now(), -agent.lookback_days * 86_400, :second)
      entries = Data.entries_window(user.id, agent.kinds, from_dt)

      case Recipe.run(agent.recipe, entries) do
        {:ok, content} ->
          store_recipe_report(run, user, agent, content, started)

        :skip ->
          {:ok, run} = complete_run(run, nil, elapsed(started))
          {:ok, nil, run}
      end
    rescue
      exception ->
        {:ok, _run} = fail_run(run, Exception.message(exception), nil, elapsed(started))
        reraise exception, __STACKTRACE__
    end
  end

  defp store_recipe_report(run, user, agent, content, started) do
    attrs = %{
      "kind" => "report",
      "source" => "agent",
      "title" => "#{agent.name} - #{Date.to_iso8601(Date.utc_today())}",
      "occurred_at" => DateTime.utc_now(),
      "data" => %{"content" => content},
      "metadata" => %{"agent_id" => agent.id, "run_id" => run.id}
    }

    case Data.create_entry(user.id, attrs) do
      {:ok, entry} ->
        {:ok, run} = complete_run(run, nil, elapsed(started))
        {:ok, entry, run}

      {:error, %Ecto.Changeset{}} ->
        {:ok, run} = fail_run(run, "could not store the report", nil, elapsed(started))
        {:error, run.error, run}
    end
  end

  defp build_context(user_id, agent) do
    from_dt = DateTime.add(DateTime.utc_now(), -agent.lookback_days * 86_400, :second)
    from_iso = DateTime.to_iso8601(from_dt)

    # all_entries/2 already orders by occurred_at desc, inserted_at desc.
    entries = Data.all_entries(user_id, %{"kinds" => agent.kinds, "from" => from_iso})

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
end
