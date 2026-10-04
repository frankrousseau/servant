defmodule ServantWeb.ConnCase do
  @moduledoc """
  This module defines the test case for the tests that must set up a
  connection.

  These tests use `Phoenix.ConnTest`. They also import other functions
  that help to build common data structures and to query the data layer.

  The module starts the SQL sandbox for each test. Then the sandbox reverts
  the changes to the database at the end of the test. A module can run its
  tests asynchronously: set `use ServantWeb.ConnCase, async: true`. The
  database is SQLite, and the writes of two async modules can collide
  ("Database busy"). Keep a module serial when that occurs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for the tests
      @endpoint ServantWeb.Endpoint

      use ServantWeb, :verified_routes

      # Import the helpers for the tests that use connections.
      import Plug.Conn
      import Phoenix.ConnTest
      import ServantWeb.ConnCase
      import Servant.Fixtures
    end
  end

  setup tags do
    Servant.DataCase.setup_sandbox(tags)

    # ConnTest gives the params directly to the controller. As a result, it
    # never sets the content-type header. A real JSON client must send this
    # header, or Plug.Parsers does not read the body. The spec validation
    # does a check of this header. For this reason, set it here and not in
    # each write test. The multipart tests override it.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  @doc """
  Registers a user and returns `{conn, user}` with a valid Bearer token set on
  the connection's `authorization` header.
  """
  def register_and_log_in_user(conn, attrs \\ %{}) do
    user = Servant.Fixtures.user_fixture(attrs)
    # Sign against the Endpoint directly, because a bare build_conn/0 has no
    # :phoenix_endpoint until the dispatch of a request.
    token = ServantWeb.Auth.sign_token(ServantWeb.Endpoint, user)
    {conn |> json_client() |> Plug.Conn.put_req_header("authorization", "Bearer #{token}"), user}
  end

  @doc """
  Registers a user and creates an API token with `scopes`. Returns
  `{conn, user}` with the plaintext of the token set as the Bearer header.
  """
  def register_and_log_in_api_token(conn, scopes, attrs \\ %{}) do
    user = Servant.Fixtures.user_fixture(attrs)

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{"name" => "test token", "scopes" => scopes})

    {conn |> json_client() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}"),
     user}
  end

  @doc """
  Marks the connection as a JSON client, the same as each real caller of the
  API. The helpers above apply it. Without it, the spec validation rejects a
  test that starts from a bare `build_conn/0`, because the content-type is
  missing.
  """
  def json_client(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [] -> Plug.Conn.put_req_header(conn, "content-type", "application/json")
      _ -> conn
    end
  end
end
