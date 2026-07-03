defmodule Servant.Fixtures do
  @moduledoc """
  Shared test fixtures. Imported by `DataCase`, `ConnCase` and `ChannelCase`.
  """

  alias Servant.Accounts
  alias Servant.Data

  @doc """
  Registers a user with sensible, unique defaults. Pass string-keyed `attrs`
  to override (`%{"username" => "...", "password" => "...", ...}`).
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
  Creates an entry for `user_id`. Pass string-keyed `attrs` to override.
  """
  def entry_fixture(user_id, attrs \\ %{}) do
    {:ok, entry} =
      Data.create_entry(
        user_id,
        Enum.into(attrs, %{
          # A neutral kind — "note" entries are managed by the Notes context and
          # are intentionally not mutable through the generic entries API.
          "kind" => "bookmark",
          "source" => "test",
          "title" => "Entry"
        })
      )

    entry
  end
end
