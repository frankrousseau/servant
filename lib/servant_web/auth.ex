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
    with {:ok, token} <- fetch_token(conn),
         {:ok, user_id} <- verify_token(conn, token),
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

  def sign_token(conn, user_id) do
    Phoenix.Token.sign(conn, "user auth", user_id)
  end

  def verify_token(conn, token) do
    Phoenix.Token.verify(conn, "user auth", token, max_age: @max_age)
  end
end
