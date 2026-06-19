defmodule Servant.Repo.Migrations.CreateEntries do
  use Ecto.Migration

  def change do
    create table(:entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :source, :string, null: false
      add :external_id, :string
      add :title, :string
      add :occurred_at, :utc_datetime
      add :data, :map, default: %{}
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:entries, [:user_id, :kind])
    create index(:entries, [:user_id, :source])
    create index(:entries, [:user_id, :occurred_at])
    create unique_index(:entries, [:user_id, :source, :external_id])
  end
end
