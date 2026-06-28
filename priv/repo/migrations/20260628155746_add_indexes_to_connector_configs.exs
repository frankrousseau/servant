defmodule Servant.Repo.Migrations.AddIndexesToConnectorConfigs do
  use Ecto.Migration

  def change do
    # list_connector_configs/1 filters by user_id; start_all_enabled/0 by enabled.
    create index(:connector_configs, [:user_id])
    create index(:connector_configs, [:enabled])
  end
end
