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

  @agent %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      name: %Schema{type: :string},
      prompt: %Schema{type: :string, nullable: true},
      mode: %Schema{type: :string, enum: ["prompt", "recipe"]},
      recipe: %Schema{type: :object, nullable: true},
      kinds: %Schema{type: :array, items: %Schema{type: :string}},
      lookback_days: %Schema{type: :integer},
      schedule: %Schema{type: :string},
      enabled: %Schema{type: :boolean},
      last_run_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"}
    }
  }
  @agent_envelope %Schema{type: :object, properties: %{data: @agent}}

  operation(:index,
    summary: "List recurring agents",
    description: "Session-only; requires agents enabled in Settings.",
    responses: [
      ok:
        {"Agents", "application/json",
         %Schema{type: :object, properties: %{data: %Schema{type: :array, items: @agent}}}},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    agents = Agents.list_agents(conn.assigns.current_user.id)
    json(conn, %{data: Enum.map(agents, &agent_json/1)})
  end

  operation(:create,
    summary: "Create a recurring agent",
    description: "Session-only; requires agents enabled in Settings.",
    request_body:
      {"Agent attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           name: %Schema{type: :string},
           prompt: %Schema{type: :string},
           mode: %Schema{type: :string, enum: ["prompt", "recipe"]},
           recipe: %Schema{type: :object},
           kinds: %Schema{type: :array, items: %Schema{type: :string}},
           lookback_days: %Schema{type: :integer},
           schedule: %Schema{type: :string},
           enabled: %Schema{type: :boolean}
         },
         required: [:name, :kinds]
       }},
    responses: [
      created: {"Agent", "application/json", @agent_envelope},
      unprocessable_entity: {"Invalid attributes", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    case Agents.create_agent(conn.assigns.current_user.id, params) do
      {:ok, agent} ->
        conn |> put_status(:created) |> json(%{data: agent_json(agent)})

      {:error, changeset} ->
        changeset_error(conn, changeset)
    end
  end

  operation(:show,
    summary: "Get one recurring agent",
    description: "Session-only; requires agents enabled in Settings.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", @agent_envelope},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    with_agent(conn, id, fn agent -> json(conn, %{data: agent_json(agent)}) end)
  end

  operation(:update,
    summary: "Update a recurring agent",
    description: "Session-only; requires agents enabled in Settings.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Agent attributes", "application/json",
       %Schema{type: :object, properties: %{}, additionalProperties: true}},
    responses: [
      ok: {"Agent", "application/json", @agent_envelope},
      unprocessable_entity: {"Invalid attributes", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    with_agent(conn, id, fn agent ->
      case Agents.update_agent(agent, params) do
        {:ok, agent} -> json(conn, %{data: agent_json(agent)})
        {:error, changeset} -> changeset_error(conn, changeset)
      end
    end)
  end

  operation(:delete,
    summary: "Delete a recurring agent",
    description: "Session-only; requires agents enabled in Settings.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: {"Deleted", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    with_agent(conn, id, fn agent ->
      {:ok, _} = Agents.delete_agent(agent)
      send_resp(conn, :no_content, "")
    end)
  end

  operation(:run,
    summary: "Run an agent now",
    description:
      "Session-only; requires agents enabled in Settings. Starts an async run on the " <>
        "configured model server and returns it for polling.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      accepted: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Agent disabled", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

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

  operation(:runs,
    summary: "List agent runs (model, tokens, duration)",
    description:
      "Session-only; requires agents enabled in Settings. Newest first, 50 max. " <>
        "Filterable by type and agent_id.",
    parameters: [
      type: [in: :query, type: :string, required: false],
      agent_id: [in: :query, type: :string, required: false]
    ],
    responses: [
      ok: {"Runs", "application/json", %Schema{type: :object}},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

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

  operation(:show_run,
    summary: "Get one agent run (for polling)",
    description: "Session-only; requires agents enabled in Settings.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Run", "application/json", %Schema{type: :object}},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def show_run(conn, %{"id" => id}) do
    case Agents.get_run(conn.assigns.current_user.id, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Run not found"})
      run -> json(conn, %{data: run_json(run)})
    end
  end

  operation(:draft_recipe,
    summary: "Draft a recipe from a plain-language description",
    description:
      "Session-only; requires agents enabled in Settings. Asks the configured model to " <>
        "translate the description into a recipe (tracked as a draft_recipe run). The " <>
        "prompt carries entry kinds and data key names, never entry values.",
    request_body:
      {"Draft request", "application/json",
       %Schema{
         type: :object,
         properties: %{
           description: %Schema{type: :string},
           kinds: %Schema{type: :array, items: %Schema{type: :string}}
         },
         required: [:description]
       }},
    responses: [
      ok: {"Recipe", "application/json", %Schema{type: :object}},
      unprocessable_entity:
        {"Invalid description or model reply", "application/json", Schemas.Error},
      forbidden: {"Agents disabled or session required", "application/json", Schemas.Error},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def draft_recipe(conn, params) do
    kinds = params["kinds"] |> List.wrap() |> Enum.filter(&is_binary/1)

    case Agents.draft_recipe(conn.assigns.current_user, params["description"], kinds) do
      {:ok, recipe, run} ->
        json(conn, %{data: %{recipe: recipe, run_id: run.id}})

      {:error, message, _run} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
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
      mode: agent.mode,
      recipe: agent.recipe,
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

  defp changeset_error(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: format_errors(changeset)})
  end
end
