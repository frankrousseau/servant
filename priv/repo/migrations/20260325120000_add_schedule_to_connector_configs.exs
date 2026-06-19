defmodule Servant.Repo.Migrations.AddScheduleToConnectorConfigs do
  use Ecto.Migration

  def change do
    alter table(:connector_configs) do
      add :schedule, :string, default: "every_hour", null: false
    end
  end
end
