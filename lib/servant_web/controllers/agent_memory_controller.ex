defmodule ServantWeb.AgentMemoryController do
  @moduledoc """
  Manages the agent memory files (memory, skills, rules of coding agents). The
  operations are the manifest, the batch upsert by path and the delete by path.
  The pull/push scripts of the `servant-memory` skill and the Agent memory app
  are the callers.
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
      pending: %Schema{
        type: :string,
        nullable: true,
        enum: ["deleted", "modified"],
        description:
          "Set by the app: `deleted` (remove the local copy at the next pull), `modified` (the Servant version wins over the local copy)"
      },
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
      "Creates or replaces each file; unchanged bodies are left alone. One invalid path rejects the whole batch. `origin: app` marks the files `modified` (or restores a soft-deleted one); without it, an agent push clears `modified` and is refused (409) on a soft-deleted path. Requires app:agent_memory:write for an API token.",
    request_body:
      {"Files", "application/json",
       %Schema{
         type: :object,
         required: [:files],
         properties: %{
           origin: %Schema{type: :string, enum: ["app", "agent"]},
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
      conflict: {"Soft-deleted in the app", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Invalid path or conflicting entry", "application/json", Schemas.Error}
    ]
  )

  def upsert(conn, %{"files" => files} = params) when is_list(files) do
    user_id = conn.assigns.current_user.id
    origin = if params["origin"] == "app", do: :app, else: :agent

    case AgentMemory.upsert_all(user_id, files, origin) do
      {:ok, entries} ->
        json(conn, %{data: Enum.map(entries, &AgentMemory.to_json/1)})

      {:error, :invalid_path} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid file path or body"})

      {:error, :conflict} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Path conflicts with an existing entry"})

      {:error, :deleted} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Deleted in the app; restore it there before pushing"})
    end
  end

  operation(:delete,
    summary: "Delete an agent memory file",
    description:
      "Soft delete: the file is marked `deleted` and every machine removes its copy at its next pull. `purge=true` removes the row for good. Requires app:agent_memory:write for an API token.",
    parameters: [
      path: [in: :query, type: :string, required: true],
      purge: [in: :query, type: :boolean, description: "Remove the row for good"]
    ],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"path" => path} = params) do
    user_id = conn.assigns.current_user.id
    purge? = params["purge"] in ["true", "1", true]

    result =
      if purge?,
        do: AgentMemory.purge(user_id, path),
        else: AgentMemory.delete(user_id, path)

    case result do
      {:ok, _entry} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
