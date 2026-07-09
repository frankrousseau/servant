defmodule Servant.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :prefix, :string, null: false
      # ecto_sqlite3 stores {:array, :string} as JSON text
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:user_id])
  end
end
