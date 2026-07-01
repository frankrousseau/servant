defmodule ServantWeb.Auth do
  @moduledoc """
  Plug that authenticates users via Bearer token.
  """

  import Plug.Conn
  alias Servant.Accounts

  @max_age 86_400 * 30
  @file_cookie "_servant_file_auth"

  def init(opts), do: opts

  @doc "Name of the HttpOnly cookie used to authenticate `/files/…` requests."
  def file_cookie_name, do: @file_cookie

  @doc """
  Sets an HttpOnly auth cookie carrying `token`, so the browser sends it
  automatically on `<img src="/files/…">` requests (which can't set an
  Authorization header). `Secure` is only set over HTTPS so dev over http works.
  """
  def put_file_cookie(conn, token) do
    Plug.Conn.put_resp_cookie(conn, @file_cookie, token,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: @max_age
    )
  end

  @doc "Clears the file auth cookie (logout)."
  def delete_file_cookie(conn) do
    Plug.Conn.delete_resp_cookie(conn, @file_cookie, http_only: true, same_site: "Lax")
  end

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user_id} <- verify_token(conn, token),
         user <- Accounts.get_user!(user_id) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "Unauthorized"})
        |> halt()
    end
  end

  def sign_token(conn, user_id) do
    Phoenix.Token.sign(conn, "user auth", user_id)
  end

  def verify_token(conn, token) do
    Phoenix.Token.verify(conn, "user auth", token, max_age: @max_age)
  end
end
