defmodule Servant.Repo.Migrations.CreatePhotoShares do
  use Ecto.Migration

  def change do
    create table(:photo_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string
      # ecto_sqlite3 stores {:array, :string} as JSON text
      add :tags, {:array, :string}, null: false
      add :match, :string, null: false, default: "any"
      add :token, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:photo_shares, [:token])
    create index(:photo_shares, [:user_id])
  end
end
