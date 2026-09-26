defmodule ServantWeb.AuthController do
  @moduledoc "Registration, login/logout, profile and password management."

  use ServantWeb, :controller
  use OpenApiSpex.ControllerSpecs
  use ServantWeb.Api.Validated

  alias OpenApiSpex.Schema
  alias Servant.Accounts
  alias Servant.Auth.Throttle
  alias ServantWeb.Auth
  alias ServantWeb.Schemas

  tags(["auth"])

  @user %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      username: %Schema{type: :string},
      display_name: %Schema{type: :string, nullable: true}
    }
  }
  @session %Schema{
    type: :object,
    properties: %{
      token: %Schema{type: :string, description: "session bearer token"},
      user: @user
    }
  }

  operation(:register,
    summary: "Register a new user",
    description: "Session-only, no auth required. Disabled when self-registration is off.",
    request_body:
      {"Credentials", "application/json",
       %Schema{
         type: :object,
         properties: %{
           username: %Schema{type: :string},
           password: %Schema{type: :string}
         },
         required: [:username, :password]
       }},
    responses: [
      created: {"Session", "application/json", @session},
      forbidden: {"Registration disabled", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

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
              display_name: user.display_name,
              avatar_path: user.avatar_path,
              theme: user.theme
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

  operation(:config,
    summary: "Public auth capabilities",
    description:
      "No auth required. Lets the SPA hide the register page/link when self-registration is off.",
    responses: [
      ok:
        {"Auth config", "application/json",
         %Schema{type: :object, properties: %{registration_enabled: %Schema{type: :boolean}}}}
    ]
  )

  @doc """
  Public auth capabilities, so the SPA can hide the register page/link when
  the operator closed self-registration (REGISTRATION_ENABLED=false).
  """
  def config(conn, _params) do
    json(conn, %{registration_enabled: registration_enabled?()})
  end

  operation(:login,
    summary: "Log in with username and password",
    description:
      "No auth required. Rate-limited per username. Returns a session directly, or a requires_totp ticket if the account has two-factor enabled.",
    request_body:
      {"Credentials", "application/json",
       %Schema{
         type: :object,
         properties: %{
           username: %Schema{type: :string},
           password: %Schema{type: :string}
         },
         required: [:username, :password]
       }},
    responses: [
      ok:
        {"Session or TOTP challenge", "application/json",
         %Schema{
           oneOf: [
             @session,
             %Schema{
               type: :object,
               properties: %{
                 requires_totp: %Schema{type: :boolean},
                 ticket: %Schema{
                   type: :string,
                   description: "short-lived, submit to /auth/totp/verify"
                 }
               }
             }
           ]
         }},
      unauthorized: {"Invalid credentials", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing fields", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error}
    ]
  )

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
        display_name: user.display_name,
        avatar_path: user.avatar_path,
        theme: user.theme
      }
    })
  end

  # ----- TOTP (two-factor authentication) -----

  # Second login step: the ticket proves the password was just verified.
  @totp_ticket_max_age 300

  operation(:totp_verify,
    summary: "Complete login with a TOTP code",
    description:
      "No auth required (uses the ticket from /auth/login instead). Rate-limited per user; wrong codes count against the ticket.",
    request_body:
      {"Ticket and code", "application/json",
       %Schema{
         type: :object,
         properties: %{
           ticket: %Schema{type: :string},
           code: %Schema{type: :string}
         },
         required: [:ticket, :code]
       }},
    responses: [
      ok: {"Session", "application/json", @session},
      unauthorized: {"Invalid or expired code", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing fields", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error}
    ]
  )

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

  operation(:totp_setup,
    summary: "Start TOTP enrollment",
    description:
      "Session-only. Returns a fresh secret (not yet persisted) plus a signed payload to submit to /auth/totp/confirm.",
    responses: [
      ok:
        {"Enrollment payload", "application/json",
         %Schema{
           type: :object,
           properties: %{
             secret: %Schema{type: :string},
             otpauth_url: %Schema{type: :string},
             payload: %Schema{type: :string}
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

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
  operation(:totp_confirm,
    summary: "Confirm TOTP enrollment",
    description: "Session-only. Proves the authenticator holds the secret from /auth/totp/setup.",
    request_body:
      {"Payload and code", "application/json",
       %Schema{
         type: :object,
         properties: %{
           payload: %Schema{type: :string},
           code: %Schema{type: :string}
         },
         required: [:payload, :code]
       }},
    responses: [
      ok:
        {"Enabled", "application/json",
         %Schema{type: :object, properties: %{totp_enabled: %Schema{type: :boolean}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid code", "application/json", Schemas.Error}
    ]
  )

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

  operation(:totp_disable,
    summary: "Disable TOTP",
    description: "Session-only. Requires the current TOTP code.",
    request_body:
      {"Code", "application/json",
       %Schema{type: :object, properties: %{code: %Schema{type: :string}}, required: [:code]}},
    responses: [
      ok:
        {"Disabled", "application/json",
         %Schema{type: :object, properties: %{totp_enabled: %Schema{type: :boolean}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid code", "application/json", Schemas.Error}
    ]
  )

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

  operation(:logout,
    summary: "Log out",
    description:
      "Session-only. Bumps token_version, so the current token (and any leaked copy) stops verifying everywhere.",
    responses: [
      ok:
        {"Status", "application/json",
         %Schema{type: :object, properties: %{status: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

  def logout(conn, _params) do
    # Bump the user's token_version so the token just used (and any leaked
    # copy) stops verifying everywhere, not only in this browser's cookie.
    Accounts.bump_token_version(conn.assigns.current_user)

    conn
    |> Auth.delete_auth_cookie()
    |> json(%{status: "ok"})
  end

  operation(:me,
    summary: "Get the current user",
    description:
      "Session-only. Also hands back a fresh session token, used by the SPA after a reload to open the realtime socket.",
    responses: [
      ok:
        {"Current user", "application/json",
         %Schema{
           type: :object,
           properties: %{
             token: %Schema{type: :string},
             data: %Schema{
               type: :object,
               properties: %{
                 id: %Schema{type: :string, format: :uuid},
                 username: %Schema{type: :string},
                 display_name: %Schema{type: :string, nullable: true},
                 email: %Schema{type: :string, nullable: true},
                 avatar_path: %Schema{type: :string, nullable: true},
                 timezone: %Schema{type: :string},
                 theme: %Schema{type: :string},
                 time_format: %Schema{type: :string, nullable: true},
                 date_format: %Schema{type: :string, nullable: true},
                 enabled_apps: %Schema{
                   type: :array,
                   items: %Schema{type: :string},
                   nullable: true,
                   description: "enabled built-in app ids; null means the default set"
                 },
                 preferences: %Schema{type: :object, description: "per-app UI preferences"},
                 totp_enabled: %Schema{type: :boolean},
                 admin: %Schema{type: :boolean},
                 inserted_at: %Schema{type: :string, format: :"date-time"}
               }
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error}
    ]
  )

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
        theme: user.theme,
        time_format: user.time_format,
        date_format: user.date_format,
        enabled_apps: user.enabled_apps,
        preferences: user.preferences,
        totp_enabled: Accounts.totp_enabled?(user),
        admin: user.admin,
        inserted_at: user.inserted_at
      }
    })
  end

  operation(:update_profile,
    summary: "Update profile fields",
    description: "Session-only.",
    request_body:
      {"Profile attributes", "application/json",
       %Schema{
         type: :object,
         properties: %{
           display_name: %Schema{type: :string},
           email: %Schema{type: :string},
           timezone: %Schema{type: :string},
           theme: %Schema{
             type: :string,
             enum: ["night", "graphite", "day", "cyanotype", "sepia", "rosewood"]
           },
           time_format: %Schema{
             type: :string,
             enum: ["24h", "12h"],
             nullable: true,
             description: "null renders times the way the browser does"
           },
           date_format: %Schema{
             type: :string,
             enum: ["dmy", "mdy", "iso"],
             nullable: true,
             description: "null renders dates the way the browser does"
           },
           enabled_apps: %Schema{
             type: :array,
             items: %Schema{type: :string},
             description: "enabled built-in app ids"
           },
           preferences: %Schema{
             type: :object,
             description:
               "per-app UI preferences, merged into the stored ones; a null value removes the key"
           }
         }
       }},
    responses: [
      ok:
        {"Profile", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{
               type: :object,
               properties: %{
                 id: %Schema{type: :string, format: :uuid},
                 username: %Schema{type: :string},
                 display_name: %Schema{type: :string, nullable: true},
                 email: %Schema{type: :string, nullable: true},
                 avatar_path: %Schema{type: :string, nullable: true},
                 timezone: %Schema{type: :string},
                 theme: %Schema{type: :string},
                 time_format: %Schema{type: :string, nullable: true},
                 date_format: %Schema{type: :string, nullable: true},
                 enabled_apps: %Schema{
                   type: :array,
                   items: %Schema{type: :string},
                   nullable: true
                 },
                 preferences: %Schema{type: :object}
               }
             }
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

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
            timezone: user.timezone,
            theme: user.theme,
            time_format: user.time_format,
            date_format: user.date_format,
            enabled_apps: user.enabled_apps,
            preferences: user.preferences
          }
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  operation(:upload_avatar,
    summary: "Upload a profile avatar",
    description: "Session-only. Multipart form with an `avatar` image field.",
    request_body:
      {"Avatar", "multipart/form-data",
       %Schema{
         type: :object,
         properties: %{avatar: %Schema{type: :string, format: :binary}},
         required: [:avatar]
       }},
    responses: [
      ok:
        {"Avatar path", "application/json",
         %Schema{
           type: :object,
           properties: %{
             data: %Schema{type: :object, properties: %{avatar_path: %Schema{type: :string}}}
           }
         }},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity: {"Upload failed", "application/json", Schemas.Error}
    ]
  )

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

  operation(:change_password,
    summary: "Change password",
    description: "Session-only.",
    request_body:
      {"Passwords", "application/json",
       %Schema{
         type: :object,
         properties: %{
           current_password: %Schema{type: :string},
           new_password: %Schema{type: :string}
         },
         required: [:current_password, :new_password]
       }},
    responses: [
      ok:
        {"Status", "application/json",
         %Schema{type: :object, properties: %{status: %Schema{type: :string}}}},
      unauthorized: {"Unauthorized", "application/json", Schemas.Error},
      forbidden: {"Session required", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Wrong password or validation errors", "application/json", Schemas.Error}
    ]
  )

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
