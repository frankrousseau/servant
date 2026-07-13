defmodule ServantWeb.Plugs.DavAuth do
  @moduledoc """
  HTTP Basic authentication for the CalDAV/CardDAV endpoint. DAV clients
  only speak Basic auth, so the password field carries a Servant token:
  an `srv_` API token (recommended; revocable and scoped to app:calendar
  / app:contacts) or a session token. The username is informative only;
  the token identifies the user. Failed `srv_` lookups feed the same
  per-IP throttle as the JSON API.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, userpass} <- Base.decode64(encoded),
         [_username, token] <- String.split(userpass, ":", parts: 2) do
      authenticate(conn, String.trim(token))
    else
      _ -> challenge(conn)
    end
  end

  defp authenticate(conn, "srv_" <> _ = token) do
    case ServantWeb.Auth.authenticate_api_token(conn, token) do
      {:ok, user, scopes} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_scopes, scopes)

      {:error, {:throttled, retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(429, "Too many attempts")
        |> halt()

      :error ->
        challenge(conn)
    end
  end

  defp authenticate(conn, token) do
    case ServantWeb.Auth.authenticate_token(conn, token) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_scopes, nil)

      :error ->
        challenge(conn)
    end
  end

  defp challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Servant CalDAV"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
