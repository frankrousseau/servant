defmodule ServantWeb.Plugs.FileAuth do
  @moduledoc """
  Authenticates `/files/…` requests from the HttpOnly `_servant_auth`
  cookie (browsers can't attach a Bearer header to `<img>`/`<a>` requests).
  Assigns `:current_user` or responds 401.
  """
  import Plug.Conn

  alias ServantWeb.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.cookies[Auth.auth_cookie_name()],
         {:ok, user} <- Auth.authenticate_token(conn, token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Unauthorized"})
        |> halt()
    end
  end
end
