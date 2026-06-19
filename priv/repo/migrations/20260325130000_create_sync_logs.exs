defmodule Servant.Repo.Migrations.CreateSyncLogs do
  use Ecto.Migration

  def change do
    create table(:sync_logs) do
      add :connector_config_id, references(:connector_configs, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :entries_count, :integer, default: 0
      add :error, :text
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:sync_logs, [:connector_config_id])
    create index(:sync_logs, [:started_at])
  end
end
