defmodule Servant.Repo.Migrations.AddNameToConnectorConfigs do
  use Ecto.Migration

  def change do
    alter table(:connector_configs) do
      add :name, :string
    end
  end
end
