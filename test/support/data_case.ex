defmodule Servant.DataCase do
  @moduledoc """
  This module defines the setup for the tests that must have access to
  the data layer of the application.

  You can define functions here and use them as helpers in your tests.

  If the test case uses the database, the module starts the SQL sandbox.
  Then the sandbox reverts the changes to the database at the end of each
  test. If you use PostgreSQL, you can also run the database tests
  asynchronously: set `use Servant.DataCase, async: true`. We do not
  recommend this option for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Servant.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Servant.DataCase
      import Servant.Fixtures
    end
  end

  setup tags do
    Servant.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Servant.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Converts the changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
