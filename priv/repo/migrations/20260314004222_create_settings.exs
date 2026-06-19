defmodule Servant.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :key, :string, null: false
      add :value, :string

      timestamps(type: :utc_datetime)
    end
  end
end
