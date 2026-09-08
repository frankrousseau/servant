defmodule ServantWeb.AgentMemoryController do
  @moduledoc """
  Agent memory files (memory, skills, rules of coding agents): manifest,
  batch upsert by path, delete by path. The pull/push scripts of the
  `servant-memory` skill and the Agent memory app are the callers.
  """

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.AgentMemory
  alias ServantWeb.Schemas

  plug ServantWeb.Plugs.Scope, domain: "agent_memory"

  tags(["agent_memory"])

  @file_schema %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      path: %Schema{
        type: :string,
        description: "memory/<project>/…, skills/<tool>/…, rules/<project>/…"
      },
      project: %Schema{type: :string, description: "Repo folder name, empty for global files"},
      tool: %Schema{type: :string, enum: ["claude", "cursor", "shared"]},
      sha256: %Schema{type: :string},
      size: %Schema{type: :integer, description: "Body size in bytes"},
      updated_at: %Schema{type: :string, format: :"date-time"},
      body: %Schema{type: :string, description: "Only with include=body"}
    }
  }
  @file_list %Schema{
    type: :object,
    properties: %{data: %Schema{type: :array, items: @file_schema}}
  }

  operation(:index,
    summary: "List agent memory files",
    description:
      "Manifest sorted by path. `project` also returns global files, `tool` also returns shared ones. Requires app:agent_memory:read for an API token.",
    parameters: [
      project: [in: :query, type: :string, description: "Repo folder name"],
      tool: [in: :query, type: :string, description: "claude or cursor"],
      include: [in: :query, type: :string, description: "`body` to include file bodies"]
    ],
    responses: [
      ok: {"Files", "application/json", @file_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    include_body? = params["include"] == "body"
    files = AgentMemory.list(user_id, Map.take(params, ["project", "tool"]))
    json(conn, %{data: Enum.map(files, &AgentMemory.to_json(&1, include_body?))})
  end

  operation(:upsert,
    summary: "Upsert agent memory files by path",
    description:
      "Creates or replaces each file; unchanged bodies are left alone. One invalid path rejects the whole batch. Requires app:agent_memory:write for an API token.",
    request_body:
      {"Files", "application/json",
       %Schema{
         type: :object,
         required: [:files],
         properties: %{
           files: %Schema{
             type: :array,
             items: %Schema{
               type: :object,
               required: [:path, :body],
               properties: %{path: %Schema{type: :string}, body: %Schema{type: :string}}
             }
           }
         }
       }},
    responses: [
      ok: {"Manifest of the files sent", "application/json", @file_list},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid path", "application/json", Schemas.Error}
    ]
  )

  def upsert(conn, %{"files" => files}) when is_list(files) do
    user_id = conn.assigns.current_user.id

    case AgentMemory.upsert_all(user_id, files) do
      {:ok, entries} ->
        json(conn, %{data: Enum.map(entries, &AgentMemory.to_json/1)})

      {:error, :invalid_path} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid file path or body"})
    end
  end

  operation(:delete,
    summary: "Delete an agent memory file",
    description: "Requires app:agent_memory:write for an API token.",
    parameters: [path: [in: :query, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"path" => path}) do
    user_id = conn.assigns.current_user.id

    case AgentMemory.delete(user_id, path) do
      {:ok, _entry} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
