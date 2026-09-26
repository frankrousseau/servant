defmodule Servant.Repo.Migrations.AddPreferencesToUsers do
  use Ecto.Migration

  # Per-app UI preferences (hidden calendars, photo grouping, ...), kept on the
  # account so they follow the user from one browser or device to the next.
  def change do
    alter table(:users) do
      add :preferences, :map, default: %{}, null: false
    end
  end
end
