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
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Registers a user and returns `{conn, user}` with a valid Bearer token set on
  the connection's `authorization` header.
  """
  def register_and_log_in_user(conn, attrs \\ %{}) do
    user = Servant.Fixtures.user_fixture(attrs)
    # Sign against the Endpoint directly — a bare build_conn/0 has no
    # :phoenix_endpoint until a request is dispatched.
    token = ServantWeb.Auth.sign_token(ServantWeb.Endpoint, user.id)
    {Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}"), user}
  end
end
