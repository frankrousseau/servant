defmodule Servant.Repo.Migrations.AddEntriesInsertedAtIndex do
  use Ecto.Migration

  # daily_stats/2 (dashboard sparklines) filters on inserted_at over a 30-day
  # window, but only occurred_at was indexed, forcing a full per-user scan on
  # every dashboard open.
  def change do
    create index(:entries, [:user_id, :inserted_at])
  end
end
