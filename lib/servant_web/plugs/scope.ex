defmodule ServantWeb.Plugs.Scope do
  @moduledoc """
  Enforces API-token scopes for a controller (optionally per action via
  `plug ... when action in [...]`). Session tokens (`api_scopes: nil`) always
  pass. GET/HEAD require `<domain>:read`, everything else `<domain>:write`.
  """

  import Plug.Conn

  alias Servant.ApiTokens.Scopes

  def init(opts), do: opts

  def call(conn, opts) do
    domain = Keyword.fetch!(opts, :domain)
    action = if conn.method in ["GET", "HEAD"], do: :read, else: :write

    if Scopes.can?(conn.assigns[:api_scopes], domain, action) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> Phoenix.Controller.json(%{
        error: "Insufficient scope",
        required: Scopes.scope_name(domain, action)
      })
      |> halt()
    end
  end
end
