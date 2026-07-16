defmodule ServantWeb.ClientErrorController do
  @moduledoc """
  Lets the SPA report client-side failures (upload conversions, etc.) so
  they land in the Audit page's error tab, which mirrors server-side
  `Logger.error` events and would otherwise never see browser-only
  errors.
  """

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs

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

  # A non-string field (e.g. `{"message": {...}}`) has no String.Chars impl, so
  # inspect it rather than let to_string/1 raise a 500.
  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @max_field)
  defp truncate(value), do: value |> inspect() |> String.slice(0, @max_field)
end
