defmodule ServantWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts with 403 unless the authenticated user is the operator (admin). Runs
  after `ServantWeb.Auth`, which assigns `:current_user` before this plug. Gates
  the operator-only endpoints (the Audit page), where the data spans all users.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{admin: true}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: "Forbidden"})
    |> halt()
  end
end
