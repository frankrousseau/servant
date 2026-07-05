defmodule ServantWeb.AuthController do
  use ServantWeb, :controller

  alias Servant.Accounts
  alias ServantWeb.Auth

  def register(conn, %{"username" => _, "password" => _} = params) do
    if registration_enabled?() do
      case Accounts.register_user(params) do
        {:ok, user} ->
          token = Auth.sign_token(conn, user.id)

          conn
          |> Auth.put_auth_cookie(token)
          |> put_status(:created)
          |> json(%{
            token: token,
            user: %{
              id: user.id,
              username: user.username,
              display_name: user.display_name
            }
          })

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Registration is disabled"})
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "username and password are required"}})
  end

  defp registration_enabled?, do: Application.get_env(:servant, :registration_enabled, true)

  @doc """
  Public auth capabilities, so the SPA can hide the register page/link when
  the operator closed self-registration (REGISTRATION_ENABLED=false).
  """
  def config(conn, _params) do
    json(conn, %{registration_enabled: registration_enabled?()})
  end

  def login(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        token = Auth.sign_token(conn, user.id)

        conn
        |> Auth.put_auth_cookie(token)
        |> json(%{
          token: token,
          user: %{
            id: user.id,
            username: user.username,
            display_name: user.display_name
          }
        })

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid username or password"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "username and password are required"}})
  end

  def logout(conn, _params) do
    conn
    |> Auth.delete_auth_cookie()
    |> json(%{status: "ok"})
  end

  def me(conn, _params) do
    user = conn.assigns.current_user

    # Also hand back a fresh token: after a reload the SPA has no token in memory
    # (it isn't stored in localStorage anymore) and uses this — authenticated via
    # the HttpOnly cookie — to open the realtime socket.
    json(conn, %{
      token: Auth.sign_token(conn, user.id),
      data: %{
        id: user.id,
        username: user.username,
        display_name: user.display_name,
        email: user.email,
        avatar_path: user.avatar_path,
        timezone: user.timezone,
        inserted_at: user.inserted_at
      }
    })
  end

  def update_profile(conn, params) do
    user = conn.assigns.current_user

    case Accounts.update_profile(user, params) do
      {:ok, user} ->
        json(conn, %{
          data: %{
            id: user.id,
            username: user.username,
            display_name: user.display_name,
            email: user.email,
            avatar_path: user.avatar_path,
            timezone: user.timezone
          }
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def upload_avatar(conn, %{"avatar" => %Plug.Upload{} = upload}) do
    user = conn.assigns.current_user

    case Accounts.update_avatar(user, upload) do
      {:ok, user} ->
        json(conn, %{data: %{avatar_path: user.avatar_path}})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to upload avatar"})
    end
  end

  def upload_avatar(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "An image file is required"})
  end

  def change_password(conn, %{"current_password" => current, "new_password" => new_password}) do
    user = conn.assigns.current_user

    case Accounts.change_password(user, current, new_password) do
      {:ok, _user} ->
        json(conn, %{status: "ok"})

      {:error, :wrong_password} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Current password is incorrect"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def change_password(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "current_password and new_password are required"})
  end
end
