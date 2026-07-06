defmodule ServantWeb.AuthControllerTest do
  use ServantWeb.ConnCase

  describe "POST /api/auth/register" do
    test "creates a user and returns a token", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{
          "username" => "newuser",
          "password" => "password123",
          "display_name" => "New User"
        })

      assert %{"token" => token, "user" => user} = json_response(conn, 201)
      assert is_binary(token)
      assert user["username"] == "newuser"
    end

    test "rejects a too-short password", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{"username" => "shorty", "password" => "short"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "rejects missing fields", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{"username" => "only"})
      assert json_response(conn, 422)
    end

    test "403 when registration is disabled (BE-SEC-9)", %{conn: conn} do
      Application.put_env(:servant, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:servant, :registration_enabled, true) end)

      conn =
        post(conn, "/api/auth/register", %{
          "username" => "blocked",
          "password" => "password123"
        })

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/auth/config" do
    test "reports registration open by default", %{conn: conn} do
      conn = get(conn, "/api/auth/config")
      assert %{"registration_enabled" => true} = json_response(conn, 200)
    end

    test "reports registration closed without requiring auth", %{conn: conn} do
      Application.put_env(:servant, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:servant, :registration_enabled, true) end)

      conn = get(conn, "/api/auth/config")
      assert %{"registration_enabled" => false} = json_response(conn, 200)
    end
  end

  describe "POST /api/auth/login" do
    setup do
      %{user: user_fixture(%{"username" => "loginuser", "password" => "password123"})}
    end

    test "returns a token for valid credentials", %{conn: conn} do
      conn =
        post(conn, "/api/auth/login", %{
          "username" => "loginuser",
          "password" => "password123"
        })

      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "sets an HttpOnly file-auth cookie (BE-SEC-1)", %{conn: conn} do
      conn =
        post(conn, "/api/auth/login", %{"username" => "loginuser", "password" => "password123"})

      cookie = conn.resp_cookies["_servant_auth"]
      assert cookie.http_only
      assert is_binary(cookie.value) and cookie.value != ""
    end

    test "logout clears the file-auth cookie", %{conn: conn} do
      {conn, _user} = register_and_log_in_user(conn)
      conn = post(conn, "/api/auth/logout", %{})
      assert conn.resp_cookies["_servant_auth"].max_age == 0
    end

    test "401 for a wrong password", %{conn: conn} do
      conn =
        post(conn, "/api/auth/login", %{"username" => "loginuser", "password" => "wrongpass1"})

      assert json_response(conn, 401)
    end

    test "422 for missing params", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{"username" => "loginuser"})
      assert json_response(conn, 422)
    end
  end

  describe "Bearer auth plug (BE-TEST-3)" do
    test "401 without a token", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert json_response(conn, 401)
    end

    test "401 with a malformed token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get("/api/auth/me")

      assert json_response(conn, 401)
    end

    test "200 with a valid token returns the current user", %{conn: conn} do
      {conn, user} = register_and_log_in_user(conn)
      conn = get(conn, "/api/auth/me")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == user.id
    end

    test "authenticates via the HttpOnly cookie without a Bearer header (FE-SEC-3)", %{conn: conn} do
      user = user_fixture()
      token = ServantWeb.Auth.sign_token(ServantWeb.Endpoint, user)

      conn =
        conn
        |> Plug.Test.put_req_cookie(ServantWeb.Auth.auth_cookie_name(), token)
        |> get("/api/auth/me")

      assert %{"data" => data, "token" => new_token} = json_response(conn, 200)
      assert data["id"] == user.id
      # me/2 hands back a fresh token for the SPA to open the socket with
      assert is_binary(new_token)
    end
  end

  describe "token revocation (token_version)" do
    alias Servant.Accounts

    setup %{conn: conn} do
      {conn, user} = register_and_log_in_user(conn)
      %{conn: conn, user: user}
    end

    test "a token stops working after the user's token_version is bumped", %{
      conn: conn,
      user: user
    } do
      assert json_response(get(conn, "/api/auth/me"), 200)

      {:ok, _} = Accounts.bump_token_version(user)

      # Same Bearer token, now stale.
      assert json_response(get(conn, "/api/auth/me"), 401)
    end

    test "logout bumps the version, invalidating the token", %{conn: conn} do
      assert json_response(post(conn, "/api/auth/logout"), 200)
      assert json_response(get(conn, "/api/auth/me"), 401)
    end

    test "changing the password invalidates existing tokens", %{conn: conn} do
      conn2 =
        put(conn, "/api/auth/password", %{
          "current_password" => "password123",
          "new_password" => "brand new pass"
        })

      assert json_response(conn2, 200)
      assert json_response(get(conn, "/api/auth/me"), 401)
    end
  end

  describe "TOTP (two-factor authentication)" do
    alias Servant.Accounts
    alias Servant.Accounts.User
    alias Servant.Repo

    @password "password123"

    # Stores a known secret directly (encrypted, no last-used timestamp) so
    # tests can mint codes without tripping the replay guard.
    defp put_totp_secret(user, secret) do
      user
      |> Ecto.Changeset.change(%{
        totp_secret: Servant.Encrypted.encrypt(secret),
        totp_last_used_at: nil
      })
      |> Repo.update!()
    end

    defp register(conn, username) do
      conn =
        post(conn, "/api/auth/register", %{"username" => username, "password" => @password})

      %{"user" => %{"id" => id}} = json_response(conn, 201)
      Repo.get!(User, id)
    end

    test "login becomes a two-step flow once TOTP is enabled", %{conn: conn} do
      user = register(conn, "totpuser")
      secret = NimbleTOTP.secret()
      put_totp_secret(user, secret)

      conn =
        post(build_conn(), "/api/auth/login", %{
          "username" => "totpuser",
          "password" => @password
        })

      assert %{"requires_totp" => true, "ticket" => ticket} = json_response(conn, 200)
      refute Map.has_key?(json_response(conn, 200), "token")

      code = NimbleTOTP.verification_code(secret)
      conn = post(build_conn(), "/api/auth/totp/verify", %{"ticket" => ticket, "code" => code})
      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "a code cannot be replayed and garbage is refused", %{conn: conn} do
      user = register(conn, "replayuser")
      secret = NimbleTOTP.secret()
      put_totp_secret(user, secret)

      login = fn ->
        conn =
          post(build_conn(), "/api/auth/login", %{
            "username" => "replayuser",
            "password" => @password
          })

        json_response(conn, 200)["ticket"]
      end

      code = NimbleTOTP.verification_code(secret)

      first = post(build_conn(), "/api/auth/totp/verify", %{"ticket" => login.(), "code" => code})
      assert json_response(first, 200)

      replay =
        post(build_conn(), "/api/auth/totp/verify", %{"ticket" => login.(), "code" => code})

      assert json_response(replay, 401)

      wrong =
        post(build_conn(), "/api/auth/totp/verify", %{"ticket" => login.(), "code" => "000000"})

      assert json_response(wrong, 401)

      bad_ticket =
        post(build_conn(), "/api/auth/totp/verify", %{"ticket" => "garbage", "code" => code})

      assert json_response(bad_ticket, 401)
    end

    test "setup then confirm enables TOTP; disable requires a valid code", %{conn: conn} do
      {conn, user} = register_and_log_in_user(conn)

      setup_conn = post(conn, "/api/auth/totp/setup")

      assert %{"secret" => secret_b32, "otpauth_url" => url, "payload" => payload} =
               json_response(setup_conn, 200)

      assert url =~ "otpauth://totp/"
      secret = Base.decode32!(secret_b32, padding: false)

      bad = post(conn, "/api/auth/totp/confirm", %{"payload" => payload, "code" => "000000"})
      assert json_response(bad, 422)
      refute Accounts.totp_enabled?(Repo.get!(User, user.id))

      code = NimbleTOTP.verification_code(secret)
      ok = post(conn, "/api/auth/totp/confirm", %{"payload" => payload, "code" => code})
      assert %{"totp_enabled" => true} = json_response(ok, 200)
      assert Accounts.totp_enabled?(Repo.get!(User, user.id))

      # A consumed code is refused; reset the replay guard to mint a new one.
      user = Repo.get!(User, user.id)
      put_totp_secret(user, secret)

      off = delete(conn, "/api/auth/totp", %{"code" => NimbleTOTP.verification_code(secret)})
      assert %{"totp_enabled" => false} = json_response(off, 200)
      refute Accounts.totp_enabled?(Repo.get!(User, user.id))
    end
  end
end
