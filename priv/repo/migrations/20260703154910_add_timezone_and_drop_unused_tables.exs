defmodule Servant.Repo.Migrations.AddTimezoneAndDropUnusedTables do
  use Ecto.Migration

  # Explicit up/down: dropping a table isn't auto-reversible in `change`, so the
  # down step recreates the (unused) credentials/settings tables to keep rollback
  # working. They match the post-UUID structure.
  def up do
    alter table(:users) do
      # IANA timezone name used for display; storage stays UTC. "UTC" until the
      # user picks one in Settings.
      add :timezone, :string, null: false, default: "UTC"
    end

    drop table(:credentials)
    drop table(:settings)
  end

  def down do
    alter table(:users) do
      remove :timezone
    end

    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :connector_type, :string, null: false
      add :data, :binary

      timestamps(type: :utc_datetime)
    end

    create table(:settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :key, :string, null: false
      add :value, :string

      timestamps(type: :utc_datetime)
    end
  end
end
