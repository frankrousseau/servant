defmodule ServantWeb.Auth do
  @moduledoc """
  Authenticates users from either an `Authorization: Bearer` header or the
  HttpOnly `_servant_auth` cookie. The cookie lets the token stay out of
  JavaScript-readable storage (defense in depth against XSS) and is sent
  automatically on same-origin requests, including `<img src="/files/…">`.
  """

  import Plug.Conn
  alias Servant.Accounts

  @max_age 86_400 * 30
  @auth_cookie "_servant_auth"

  def init(opts), do: opts

  @doc "Name of the HttpOnly cookie carrying the auth token."
  def auth_cookie_name, do: @auth_cookie

  @doc """
  Sets the HttpOnly auth cookie carrying `token`. `SameSite=Lax` keeps
  state-changing cross-site requests from carrying it (CSRF), while same-origin
  API/file requests still send it. `Secure` only over HTTPS so dev over http works.
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

  # API tokens (srv_ prefix): DB lookup by hash, scopes attached. Failed lookups
  # feed the per-IP throttle so token values can't be brute forced.
  defp authenticate_request(conn, "srv_" <> _ = token) do
    throttle_key = "api_token:" <> ip_string(conn)

    with :ok <- Servant.Auth.Throttle.check(throttle_key),
         {:ok, user, scopes} <- Servant.ApiTokens.authenticate(token) do
      Servant.Auth.Throttle.reset(throttle_key)

      conn
      |> assign(:current_user, user)
      |> assign(:api_scopes, scopes)
    else
      {:error, retry_after} ->
        conn
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{error: "Too many attempts", retry_after: retry_after})
        |> halt()

      :error ->
        Servant.Auth.Throttle.record_failure(throttle_key)
        unauthorized(conn)
    end
  end

  # Session tokens (Phoenix.Token): full access, api_scopes stays nil.
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

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "Unauthorized"})
    |> halt()
  end

  defp ip_string(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  # Bearer header takes precedence; fall back to the HttpOnly cookie.
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
  Signs an auth token binding the user id to their current `token_version`.
  Bumping `token_version` (logout, password change, TOTP disable) invalidates
  every token signed before the bump.
  """
  def sign_token(conn, %{id: user_id} = user) do
    Phoenix.Token.sign(conn, "user auth", {user_id, Map.get(user, :token_version, 0)})
  end

  def verify_token(conn, token) do
    Phoenix.Token.verify(conn, "user auth", token, max_age: @max_age)
  end

  @doc """
  Verifies a token and returns the live user only when the embedded
  `token_version` still matches the stored one. Single source of truth for
  both the HTTP plug and the socket so they can't drift.
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
