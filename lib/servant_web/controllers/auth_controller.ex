defmodule ServantWeb.AuthController do
  @moduledoc "Registration, login/logout, profile and password management."

  use ServantWeb, :controller

  alias Servant.Accounts
  alias Servant.Auth.Throttle
  alias ServantWeb.Auth

  def register(conn, %{"username" => _, "password" => _} = params) do
    if registration_enabled?() do
      case Accounts.register_user(params) do
        {:ok, user} ->
          token = Auth.sign_token(conn, user)

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
    key = "login:" <> String.downcase(username)

    case Throttle.check(key) do
      {:error, retry_after} ->
        too_many(conn, retry_after)

      :ok ->
        case Accounts.authenticate_user(username, password) do
          {:ok, user} ->
            Throttle.reset(key)

            if Accounts.totp_enabled?(user) do
              # Password checked out but the session only opens after the TOTP
              # step: hand back a short-lived ticket instead of a token.
              ticket = Phoenix.Token.sign(conn, "totp pending", user.id)
              json(conn, %{requires_totp: true, ticket: ticket})
            else
              issue_session(conn, user)
            end

          {:error, :invalid_credentials} ->
            Throttle.record_failure(key)

            conn
            |> put_status(:unauthorized)
            |> json(%{error: "Invalid username or password"})
        end
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "username and password are required"}})
  end

  defp too_many(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_status(:too_many_requests)
    |> json(%{error: "Too many attempts, try again later"})
  end

  defp issue_session(conn, user) do
    token = Auth.sign_token(conn, user)

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
  end

  # ----- TOTP (two-factor authentication) -----

  # Second login step: the ticket proves the password was just verified.
  @totp_ticket_max_age 300

  def totp_verify(conn, %{"ticket" => ticket, "code" => code}) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(conn, "totp pending", ticket, max_age: @totp_ticket_max_age),
         key = "totp:" <> user_id,
         :ok <- Throttle.check(key),
         user when not is_nil(user) <- Accounts.get_user(user_id),
         {:ok, user} <- Accounts.verify_totp(user, code) do
      Throttle.reset(key)
      issue_session(conn, user)
    else
      {:error, retry_after} when is_integer(retry_after) ->
        too_many(conn, retry_after)

      _ ->
        # Count the bad code against the user's ticket, throttling guesses.
        with {:ok, user_id} <-
               Phoenix.Token.verify(conn, "totp pending", ticket, max_age: @totp_ticket_max_age) do
          Throttle.record_failure("totp:" <> user_id)
        end

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or expired code"})
    end
  end

  def totp_verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "ticket and code are required"}})
  end

  # Enrollment step 1: a fresh secret, never persisted at this point. It
  # travels back inside a signed payload so confirm can stay stateless.
  @totp_setup_max_age 600

  def totp_setup(conn, _params) do
    user = conn.assigns.current_user
    secret = NimbleTOTP.secret()
    payload = Phoenix.Token.sign(conn, "totp setup", Base.encode64(secret))

    json(conn, %{
      secret: Base.encode32(secret, padding: false),
      otpauth_url: NimbleTOTP.otpauth_uri("Servant:#{user.username}", secret, issuer: "Servant"),
      payload: payload
    })
  end

  # Enrollment step 2: prove the authenticator holds the secret.
  def totp_confirm(conn, %{"payload" => payload, "code" => code}) do
    user = conn.assigns.current_user

    with {:ok, encoded} <-
           Phoenix.Token.verify(conn, "totp setup", payload, max_age: @totp_setup_max_age),
         {:ok, secret} <- Base.decode64(encoded),
         {:ok, _user} <- Accounts.enable_totp(user, secret, code) do
      json(conn, %{totp_enabled: true})
    else
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid code, scan the QR again and retry"})
    end
  end

  def totp_disable(conn, %{"code" => code}) do
    user = conn.assigns.current_user

    case Accounts.disable_totp(user, code) do
      {:ok, _user} ->
        json(conn, %{totp_enabled: false})

      {:error, :invalid_code} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid code"})
    end
  end

  def logout(conn, _params) do
    # Bump the user's token_version so the token just used (and any leaked
    # copy) stops verifying everywhere, not only in this browser's cookie.
    Accounts.bump_token_version(conn.assigns.current_user)

    conn
    |> Auth.delete_auth_cookie()
    |> json(%{status: "ok"})
  end

  def me(conn, _params) do
    user = conn.assigns.current_user

    # Also hand back a fresh token: after a reload the SPA has no token in memory
    # (it isn't stored in localStorage anymore) and uses this (authenticated via
    # the HttpOnly cookie) to open the realtime socket.
    json(conn, %{
      token: Auth.sign_token(conn, user),
      data: %{
        id: user.id,
        username: user.username,
        display_name: user.display_name,
        email: user.email,
        avatar_path: user.avatar_path,
        timezone: user.timezone,
        totp_enabled: Accounts.totp_enabled?(user),
        admin: user.admin,
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
