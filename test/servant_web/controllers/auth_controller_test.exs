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

      cookie = conn.resp_cookies["_servant_file_auth"]
      assert cookie.http_only
      assert is_binary(cookie.value) and cookie.value != ""
    end

    test "logout clears the file-auth cookie", %{conn: conn} do
      conn = post(conn, "/api/auth/logout", %{})
      assert conn.resp_cookies["_servant_file_auth"].max_age == 0
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
  end
end
