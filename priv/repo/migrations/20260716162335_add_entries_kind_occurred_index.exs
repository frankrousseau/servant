defmodule Servant.Repo.Migrations.AddEntriesKindOccurredIndex do
  use Ecto.Migration

  # The default entry listing filters by kind and sorts by occurred_at desc.
  # Neither (user_id, kind) nor (user_id, occurred_at) alone lets SQLite both
  # filter and return rows already ordered, so it sorts the whole kind on every
  # timeline page. This composite covers filter + order in one index scan.
  def change do
    create index(:entries, [:user_id, :kind, :occurred_at])
  end
end
