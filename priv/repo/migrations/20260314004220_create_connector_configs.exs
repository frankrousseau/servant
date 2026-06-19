defmodule Servant.Repo.Migrations.CreateConnectorConfigs do
  use Ecto.Migration

  def change do
    create table(:connector_configs) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :connector_type, :string, null: false
      add :enabled, :boolean, default: false
      add :config, :map, default: %{}
      add :last_synced_at, :utc_datetime
      add :error, :string

      timestamps(type: :utc_datetime)
    end
  end
end
