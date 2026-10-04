defmodule ServantWeb.ChannelCase do
  @moduledoc """
  This module defines the test case that the channel tests use.

  These tests use `Phoenix.ChannelTest`. They also import other functions
  that help to build common data structures and to query the data layer.

  The module starts the SQL sandbox for each test. Then the sandbox reverts
  the changes to the database at the end of the test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for the tests
      @endpoint ServantWeb.Endpoint

      # Import the helpers for the tests that use channels.
      import Phoenix.ChannelTest
      import Servant.Fixtures
      import ServantWeb.ChannelCase
    end
  end

  setup tags do
    Servant.DataCase.setup_sandbox(tags)
    :ok
  end
end
