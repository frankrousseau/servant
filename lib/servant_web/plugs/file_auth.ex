defmodule ServantWeb.Plugs.FileAuth do
  @moduledoc """
  Authenticates `/files/…` requests from the HttpOnly `_servant_file_auth`
  cookie (browsers can't attach a Bearer header to `<img>`/`<a>` requests).
  Assigns `:current_user` or responds 401.
  """
  import Plug.Conn

  alias Servant.Accounts
  alias ServantWeb.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.cookies[Auth.file_cookie_name()],
         {:ok, user_id} <- Auth.verify_token(conn, token),
         user when not is_nil(user) <- Accounts.get_user(user_id) do
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
