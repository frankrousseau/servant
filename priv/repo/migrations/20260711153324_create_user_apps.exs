defmodule Servant.Repo.Migrations.CreateUserApps do
  use Ecto.Migration

  def change do
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

    create unique_index(:user_apps, [:user_id, :app_id])
  end
end
