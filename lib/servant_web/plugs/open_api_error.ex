defmodule ServantWeb.Plugs.OpenApiError do
  @moduledoc """
  Renders OpenApiSpex cast failures in the API's own error envelope
  (`%{"error" => message}`), so a request rejected by the spec looks like every
  other 422 instead of switching to the library's JSON:API-ish shape.
  """

  @behaviour Plug

  alias OpenApiSpex.Cast.Error
  alias Plug.Conn

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    message = Enum.map_join(errors, "; ", &describe/1)

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(422, Jason.encode!(%{error: "Invalid request: #{message}"}))
  end

  # "#/kind: is required" rather than just "is required": with several errors
  # in one response, the field is the useful half.
  defp describe(%Error{} = error) do
    case Error.path_to_string(error) do
      "" -> Error.message(error)
      path -> "#{path}: #{Error.message(error)}"
    end
  end

  defp describe(other), do: to_string(other)
end
