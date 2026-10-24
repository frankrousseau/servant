defmodule ServantWeb.Auth do
  @moduledoc """
  Authenticates users from an `Authorization: Bearer` header or from the
  HttpOnly `_servant_auth` cookie. The cookie keeps the token out of the
  storage that JavaScript can read (defense in depth against XSS). The browser
  sends the cookie automatically on same-origin requests, and
  `<img src="/files/…">` is one of them.
  """

  import Plug.Conn
  alias Servant.Accounts

  @max_age 86_400 * 30
  @auth_cookie "_servant_auth"

  def init(opts), do: opts

  @doc "Returns the name of the HttpOnly cookie that carries the auth token."
  def auth_cookie_name, do: @auth_cookie

  @doc """
  Sets the HttpOnly auth cookie that carries `token`. With `SameSite=Lax`,
  cross-site requests that change state do not carry the cookie (CSRF), but
  same-origin API and file requests continue to send it. The cookie is `Secure`
  only over HTTPS, so that dev over http works.
  """
  def put_auth_cookie(conn, token) do
    Plug.Conn.put_resp_cookie(conn, @auth_cookie, token,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: @max_age
    )
  end

  @doc "Clears the auth cookie (logout)."
  def delete_auth_cookie(conn) do
    Plug.Conn.delete_resp_cookie(conn, @auth_cookie, http_only: true, same_site: "Lax")
  end

  def call(conn, _opts) do
    case fetch_token(conn) do
      {:ok, token} -> authenticate_request(conn, token)
      :error -> unauthorized(conn)
    end
  end

  # API tokens (srv_ prefix): the DB lookup is by hash and it attaches the scopes.
  # Failed lookups feed the per-IP throttle, so a brute-force attack cannot find
  # the token values.
  defp authenticate_request(conn, "srv_" <> _ = token) do
    case authenticate_api_token(conn, token) do
      {:ok, user, scopes} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_scopes, scopes)

      {:error, {:throttled, retry_after}} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "Too many attempts", retry_after: retry_after})
        |> halt()

      :error ->
        unauthorized(conn)
    end
  end

  # Session tokens (Phoenix.Token) give full access, and api_scopes stays nil.
  defp authenticate_request(conn, token) do
    case authenticate_token(conn, token) do
      {:ok, user} ->
        conn
        |> assign(:current_user, user)
        |> assign(:api_scopes, nil)

      :error ->
        unauthorized(conn)
    end
  end

  @doc """
  Authenticates an `srv_` API token and keeps the per-IP throttle up to date.
  This plug and `FileAuth` share this function, so each surface throttles a
  brute-force attack the same way. Returns `{:ok, user, scopes}`,
  `{:error, {:throttled, retry_after}}` or `:error`.
  """
  def authenticate_api_token(conn, "srv_" <> _ = token) do
    throttle_key = "api_token:" <> ip_string(conn)

    with :ok <- Servant.Auth.Throttle.check(throttle_key),
         {:ok, user, scopes} <- Servant.ApiTokens.authenticate(token) do
      Servant.Auth.Throttle.reset(throttle_key)
      {:ok, user, scopes}
    else
      {:error, retry_after} ->
        {:error, {:throttled, retry_after}}

      :error ->
        Servant.Auth.Throttle.record_failure(throttle_key)
        :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "Unauthorized"})
    |> halt()
  end

  defp ip_string(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # The Bearer header has priority. If it is absent, use the HttpOnly cookie.
  defp fetch_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, token}

      _ ->
        conn = fetch_cookies(conn)

        case conn.cookies[@auth_cookie] do
          token when is_binary(token) -> {:ok, token}
          _ -> :error
        end
    end
  end

  @doc """
  Signs an auth token that binds the user id to the current `token_version` of
  the user. An increment of `token_version` (logout, password change, TOTP
  disable) invalidates each token signed before the increment.
  """
  def sign_token(conn, %{id: user_id} = user) do
    Phoenix.Token.sign(conn, "user auth", {user_id, Map.get(user, :token_version, 0)})
  end

  def verify_token(conn, token) do
    Phoenix.Token.verify(conn, "user auth", token, max_age: @max_age)
  end

  @doc """
  Verifies a token and returns the live user only when the embedded
  `token_version` still matches the stored one. This function is the single
  source of truth for the HTTP plug and the socket, so they cannot drift apart.
  """
  def authenticate_token(context, token) do
    with {:ok, {user_id, version}} <- verify_token(context, token),
         user when not is_nil(user) <- Accounts.get_user(user_id),
         true <- user.token_version == version do
      {:ok, user}
    else
      _ -> :error
    end
  end
end
