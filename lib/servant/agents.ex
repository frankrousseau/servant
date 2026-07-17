defmodule Servant.Agents do
  @moduledoc """
  Shared bookkeeping for AI agent runs. Every run records the model used,
  the tokens consumed and its duration (Sustainable AI manifesto). v1 only
  ships the "builder" type; explorer and recurrent agents will reuse this.
  """

  import Ecto.Query

  alias Servant.Accounts
  alias Servant.Agents.Agent
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
      user = Accounts.get_user(agent.user_id)

      if user && Accounts.ai_enabled?(user) do
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
