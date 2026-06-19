defmodule Servant.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  def change do
    create table(:credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :connector_type, :string, null: false
      add :data, :binary

      timestamps(type: :utc_datetime)
    end
  end
end
