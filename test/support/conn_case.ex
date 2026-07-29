defmodule ServantWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ServantWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ServantWeb.Endpoint

      use ServantWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ServantWeb.ConnCase
      import Servant.Fixtures
    end
  end

  setup tags do
    Servant.DataCase.setup_sandbox(tags)

    # ConnTest hands params straight to the controller, so it never sets the
    # content-type a real JSON client must send for Plug.Parsers to read the
    # body at all. Spec validation checks that header, so set it here rather
    # than in every write test (multipart tests override it).
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
    # Sign against the Endpoint directly, since a bare build_conn/0 has no
    # :phoenix_endpoint until a request is dispatched.
    token = ServantWeb.Auth.sign_token(ServantWeb.Endpoint, user)
    {conn |> json_client() |> Plug.Conn.put_req_header("authorization", "Bearer #{token}"), user}
  end

  @doc """
  Registers a user, creates an API token with `scopes` and returns
  `{conn, user}` with the token's plaintext set as Bearer header.
  """
  def register_and_log_in_api_token(conn, scopes, attrs \\ %{}) do
    user = Servant.Fixtures.user_fixture(attrs)

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{"name" => "test token", "scopes" => scopes})

    {conn |> json_client() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}"),
     user}
  end

  @doc """
  Marks the connection as a JSON client, the way any real caller reaches the
  API. Applied by the helpers above so a test starting from a bare
  `build_conn/0` isn't rejected by spec validation over a missing content-type.
  """
  def json_client(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [] -> Plug.Conn.put_req_header(conn, "content-type", "application/json")
      _ -> conn
    end
  end
end
