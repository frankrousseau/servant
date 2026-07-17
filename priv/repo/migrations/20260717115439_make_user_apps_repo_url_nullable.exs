defmodule Servant.Repo.Migrations.MakeUserAppsRepoUrlNullable do
  @moduledoc """
  Widens `user_apps.repo_url` to allow nil (generated apps have no git
  repository). exqlite/ecto_sqlite3 does not support `ALTER COLUMN`, so this
  recreates the table (SQLite's standard 12-step ALTER TABLE procedure)
  instead of using `modify`.
  """

  use Ecto.Migration

  @columns "id, user_id, app_id, name, description, icon, entry, repo_url, inserted_at, updated_at"

  def up do
    rename table(:user_apps), to: table(:user_apps_old)

    create table(:user_apps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :app_id, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :icon, :string
      add :entry, :string, null: false
      add :repo_url, :string, null: true

      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO user_apps (#{@columns}) SELECT #{@columns} FROM user_apps_old"

    drop table(:user_apps_old)

    create unique_index(:user_apps, [:user_id, :app_id])
  end

  def down do
    rename table(:user_apps), to: table(:user_apps_old)

    create table(:user_apps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :app_id, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :icon, :string
      add :entry, :string, null: false
      add :repo_url, :string, null: false

      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO user_apps (#{@columns}) SELECT #{@columns} FROM user_apps_old"

    drop table(:user_apps_old)

    create unique_index(:user_apps, [:user_id, :app_id])
  end
end
