defmodule ServantWeb.Plugs.OpenApiError do
  @moduledoc """
  Renders OpenApiSpex cast failures in the error envelope of the API
  (`%{"error" => message}`). As a result, a request that the spec rejects looks
  like all the other 422s. It does not change to the JSON:API-ish shape of the
  library.
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

  # Returns "#/kind: is required" and not only "is required". With several
  # errors in one response, the field is the useful half.
  defp describe(%Error{} = error) do
    case Error.path_to_string(error) do
      "" -> Error.message(error)
      path -> "#{path}: #{Error.message(error)}"
    end
  end

  defp describe(other), do: to_string(other)
end
