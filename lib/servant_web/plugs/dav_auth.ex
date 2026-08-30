defmodule ServantWeb.Plugs.DavAuth do
  @moduledoc """
  HTTP Basic authentication for the CalDAV/CardDAV endpoint. DAV clients
  only speak Basic auth, so the password field carries a Servant token:
  an `srv_` API token (recommended; revocable and scoped to app:calendar
  / app:contacts) or a session token. The username is informative only;
  the token identifies the user. Failed `srv_` lookups feed the same
  per-IP throttle as the JSON API.

  Every challenge logs why (missing header, other scheme, malformed
  credentials, rejected token) so a phone client that "always gets 401"
  can be diagnosed from the server log; the token itself is never logged.
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded] -> decode(conn, encoded)
      [] -> challenge(conn, "no authorization header")
      [other] -> challenge(conn, "unsupported scheme #{scheme(other)}")
      _ -> challenge(conn, "several authorization headers")
    end
  end

  defp decode(conn, encoded) do
    with {:ok, userpass} <- Base.decode64(encoded),
         [_username, token] <- String.split(userpass, ":", parts: 2) do
      authenticate(conn, String.trim(token))
    else
      _ -> challenge(conn, "malformed basic credentials")
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
        challenge(conn, "unknown or expired srv_ token (#{byte_size(token)} bytes)")
    end
  end

  defp authenticate(conn, token) do
    case ServantWeb.Auth.authenticate_token(conn, token) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_scopes, nil)

      :error ->
        challenge(conn, "invalid session token (#{byte_size(token)} bytes, no srv_ prefix)")
    end
  end

  defp challenge(conn, reason) do
    Logger.warning("dav auth challenge (#{conn.method} #{conn.request_path}): #{reason}")

    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="Servant CalDAV"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  # Only the scheme word, never the credential that follows it.
  defp scheme(header), do: header |> String.split(" ", parts: 2) |> hd()
end
