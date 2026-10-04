defmodule ServantWeb.Plugs.RequireAgents do
  @moduledoc "Halts with a 403 unless the current user turned on AI agents in Settings."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Servant.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if Accounts.ai_enabled?(conn.assigns.current_user) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "AI agents are disabled in Settings"})
      |> halt()
    end
  end
end
