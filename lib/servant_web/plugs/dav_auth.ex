defmodule ServantWeb.Plugs.DavAuth do
  @moduledoc """
  HTTP Basic authentication for the CalDAV/CardDAV endpoint.

  DAV clients only speak Basic auth, so the password field carries a Servant
  token. The token is an `srv_` API token or a session token. The `srv_` API
  token is the recommended one: it is revocable and scoped to app:calendar
  / app:contacts. The username is informative only. The token identifies
  the user. Failed `srv_` lookups feed the same per-IP throttle as the JSON API.

  Each challenge logs its cause (missing header, other scheme, malformed
  credentials, rejected token). As a result, the server log is sufficient to
  diagnose a phone client that "always gets 401". The log never contains the
  token itself.
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

  # Returns only the scheme word, never the credential that follows it.
  defp scheme(header), do: header |> String.split(" ", parts: 2) |> hd()
end
