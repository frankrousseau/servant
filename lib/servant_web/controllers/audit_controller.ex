defmodule ServantWeb.AuditController do
  @moduledoc "System stats and log buffers backing the Audit page."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Audit
  alias Servant.Audit.LogBuffer
  alias ServantWeb.Schemas

  tags(["audit"])

  operation(:system,
    summary: "Server-wide system stats",
    description: "Session-only, operator (admin) only.",
    responses: [
      ok:
        {"System stats", "application/json", %Schema{type: :object, additionalProperties: true}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Not an operator", "application/json", Schemas.Error}
    ]
  )

  def system(conn, _params) do
    json(conn, %{data: Audit.system_stats()})
  end

  operation(:logs,
    summary: "In-memory access/error log buffer",
    description:
      "Session-only, operator (admin) only. All users' requests, since these logs span the whole server.",
    parameters: [
      type: [
        in: :query,
        type: :string,
        required: false,
        description: "\"error\" for the error buffer, defaults to the access-log buffer"
      ]
    ],
    responses: [
      ok:
        {"Log entries", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :array,
               items: %Schema{type: :object, additionalProperties: true}
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Not an operator", "application/json", Schemas.Error}
    ]
  )

  def logs(conn, %{"type" => "error"}), do: json(conn, %{data: LogBuffer.error_logs()})
  def logs(conn, _params), do: json(conn, %{data: LogBuffer.access_logs()})
end
