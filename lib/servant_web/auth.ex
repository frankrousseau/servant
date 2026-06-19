defmodule ServantWeb.Auth do
  @moduledoc """
  Plug that authenticates users via Bearer token.
  """

  import Plug.Conn
  alias Servant.Accounts

  @max_age 86_400 * 30

  def init(opts), do: opts

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
