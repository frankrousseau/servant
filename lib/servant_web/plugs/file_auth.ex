defmodule ServantWeb.Plugs.FileAuth do
  @moduledoc """
  Authenticates `/files/…` requests. Browsers use the HttpOnly
  `_servant_auth` cookie, because they cannot attach a Bearer header to
  `<img>`/`<a>` requests. Scripts can use an `srv_` API token that carries
  the explicit `data:read-binary` scope. Assigns `:current_user` or responds
  with 401/403.
  """
  import Plug.Conn

  alias Servant.ApiTokens.Scopes
  alias ServantWeb.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer srv_" <> rest] -> api_token_auth(conn, "srv_" <> rest)
      _ -> cookie_auth(conn)
    end
  end

  # Raw bytes are a deliberate opt-in. The token must carry data:read-binary,
  # and data:read/data:write never imply that scope.
  defp api_token_auth(conn, token) do
    case Auth.authenticate_api_token(conn, token) do
      {:ok, user, scopes} ->
        if Scopes.can_read_binary?(scopes) do
          conn
          |> assign(:current_user, user)
          |> assign(:api_scopes, scopes)
        else
          conn
          |> put_status(:forbidden)
          |> Phoenix.Controller.json(%{
            error: "Insufficient scope",
            required: "data:read-binary"
          })
          |> halt()
        end

      {:error, {:throttled, retry_after}} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "Too many attempts", retry_after: retry_after})
        |> halt()

      :error ->
        unauthorized(conn)
    end
  end

  defp cookie_auth(conn) do
    conn = fetch_cookies(conn)

    with token when is_binary(token) <- conn.cookies[Auth.auth_cookie_name()],
         {:ok, user} <- Auth.authenticate_token(conn, token) do
      assign(conn, :current_user, user)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "Unauthorized"})
    |> halt()
  end
end
