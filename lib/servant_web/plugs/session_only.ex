defmodule ServantWeb.Plugs.SessionOnly do
  @moduledoc """
  Rejects API tokens. Account management, connectors, audit and token
  management are reserved to interactive sessions so a leaked token can't
  escalate (create tokens, change the password, read other domains).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if is_nil(conn.assigns[:api_scopes]) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{error: "Session required (API tokens not allowed)"})
      |> halt()
    end
  end
end
