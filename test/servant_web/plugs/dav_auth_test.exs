defmodule ServantWeb.Plugs.DavAuthTest do
  use ServantWeb.ConnCase

  import ExUnit.CaptureLog

  alias Servant.ApiTokens
  alias Servant.Auth.Throttle
  alias ServantWeb.Auth
  alias ServantWeb.Plugs.DavAuth

  defp call(conn), do: DavAuth.call(conn, DavAuth.init([]))

  defp basic(conn, username, password) do
    credentials = Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp dav_conn do
    :propfind
    |> Phoenix.ConnTest.build_conn("/dav/calendars")
    |> Plug.Conn.put_private(:phoenix_endpoint, ServantWeb.Endpoint)
  end

  describe "challenges" do
    test "no authorization header" do
      conn = call(dav_conn())

      assert conn.status == 401
      assert conn.halted
      assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Servant CalDAV")]
    end

    test "another scheme is refused, and only the scheme word is logged" do
      log =
        capture_log(fn ->
          conn = put_req_header(dav_conn(), "authorization", "Bearer sup3rs3cr3t") |> call()
          assert conn.status == 401
        end)

      assert log =~ "unsupported scheme Bearer"
      refute log =~ "sup3rs3cr3t"
    end

    test "credentials that are not base64" do
      conn = put_req_header(dav_conn(), "authorization", "Basic !!not-base64!!") |> call()
      assert conn.status == 401
    end

    test "credentials without a colon" do
      conn =
        put_req_header(dav_conn(), "authorization", "Basic #{Base.encode64("nocolon")}")
        |> call()

      assert conn.status == 401
    end
  end

  describe "session tokens" do
    test "a valid session token authenticates, with no API scopes" do
      user = user_fixture()
      token = Auth.sign_token(ServantWeb.Endpoint, user)

      conn = dav_conn() |> basic(user.username, token) |> call()

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.api_scopes == nil
    end

    # The username field is informative: the token alone identifies the user.
    test "the username is ignored" do
      user = user_fixture()
      token = Auth.sign_token(ServantWeb.Endpoint, user)

      conn = dav_conn() |> basic("whatever", token) |> call()

      assert conn.assigns.current_user.id == user.id
    end

    test "an invalid session token is challenged without logging the token" do
      log =
        capture_log(fn ->
          conn = dav_conn() |> basic("someone", "totally-invalid-token") |> call()
          assert conn.status == 401
        end)

      assert log =~ "invalid session token"
      refute log =~ "totally-invalid-token"
    end
  end

  describe "srv_ API tokens" do
    setup do
      user = user_fixture()

      {:ok, _token, plaintext} =
        ApiTokens.create_token(user.id, %{
          "name" => "phone",
          "scopes" => ["app:calendar:read"]
        })

      %{user: user, plaintext: plaintext}
    end

    test "a valid API token carries its scopes", %{user: user, plaintext: plaintext} do
      conn = dav_conn() |> basic(user.username, plaintext) |> call()

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.api_scopes == ["app:calendar:read"]
    end

    test "surrounding whitespace is trimmed", %{user: user, plaintext: plaintext} do
      conn = dav_conn() |> basic(user.username, " #{plaintext}\n") |> call()

      assert conn.assigns.current_user.id == user.id
    end

    test "an unknown srv_ token is challenged", %{user: user} do
      conn = dav_conn() |> basic(user.username, "srv_nope") |> call()
      assert conn.status == 401
    end

    # Failed srv_ lookups feed the same per-IP throttle as the JSON API.
    test "repeated failures are throttled with a retry-after", %{user: user} do
      # The throttle is global per IP, and other suites also hit 127.0.0.1.
      key = "api_token:127.0.0.1"
      Throttle.reset(key)
      on_exit(fn -> Throttle.reset(key) end)

      for _ <- 1..10 do
        assert dav_conn() |> basic(user.username, "srv_nope") |> call() |> Map.get(:status) == 401
      end

      conn = dav_conn() |> basic(user.username, "srv_nope") |> call()

      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end
  end
end
