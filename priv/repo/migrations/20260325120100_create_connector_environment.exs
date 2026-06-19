defmodule Servant.Repo.Migrations.CreateConnectorEnvironment do
  use Ecto.Migration

  def change do
    create table(:connector_environment) do
      add :connector_type, :string, null: false
      add :namespace, :string, null: false
      add :key, :string, null: false
      add :value, :map, null: false, default: %{}
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:connector_environment, [:connector_type, :namespace, :key])
    create index(:connector_environment, [:expires_at])
  end
end
