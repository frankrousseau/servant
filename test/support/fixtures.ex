defmodule Servant.Fixtures do
  @moduledoc """
  Shared test fixtures. `DataCase`, `ConnCase` and `ChannelCase` import them.
  """

  alias Servant.Accounts
  alias Servant.Data

  @doc """
  Registers a user with sensible, unique defaults. To override them, pass
  `attrs` with string keys (`%{"username" => "...", "password" => "...", ...}`).
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(
        Enum.into(attrs, %{
          "username" => "user#{n}",
          "password" => "password123",
          "display_name" => "User #{n}"
        })
      )

    user
  end

  @doc """
  Creates an entry for `user_id`. To override the defaults, pass `attrs` with
  string keys.
  """
  def entry_fixture(user_id, attrs \\ %{}) do
    {:ok, entry} =
      Data.create_entry(
        user_id,
        Enum.into(attrs, %{
          # A neutral kind. The Notes context manages the "note" entries. On
          # purpose, the generic entries API cannot change them.
          "kind" => "bookmark",
          "source" => "test",
          "title" => "Entry"
        })
      )

    entry
  end
end
