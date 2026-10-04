defmodule ServantWeb.ClientErrorController do
  @moduledoc """
  Lets the SPA report client-side failures (upload conversions, for example).
  The failures then go to the error tab of the Audit page. That tab mirrors
  the server-side `Logger.error` events. Without this controller, it never
  sees browser-only errors.
  """

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  require Logger

  alias OpenApiSpex.Schema
  alias ServantWeb.Schemas

  @max_field 500

  tags(["audit"])

  operation(:create,
    summary: "Report a client-side error",
    description:
      "Logs a browser-side failure server-side so it shows up in the Audit error logs.",
    request_body:
      {"Client error", "application/json",
       %Schema{
         type: :object,
         properties: %{
           context: %Schema{type: :string, description: "where it happened, e.g. photos-upload"},
           message: %Schema{type: :string}
         },
         required: [:message]
       }},
    responses: [
      no_content: {"Recorded", nil, nil},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    context = truncate(params["context"] || "unknown")
    message = truncate(params["message"] || "")
    user_id = conn.assigns.current_user.id

    Logger.error("client error [#{context}] user=#{user_id}: #{message}")
    send_resp(conn, 204, "")
  end

  # A non-string field (for example `{"message": {...}}`) has no String.Chars
  # impl. Inspect it, so that to_string/1 does not raise a 500.
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @max_field)
  defp truncate(value), do: value |> inspect() |> String.slice(0, @max_field)
end
