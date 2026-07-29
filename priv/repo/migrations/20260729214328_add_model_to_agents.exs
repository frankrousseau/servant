defmodule Servant.Repo.Migrations.AddModelToAgents do
  use Ecto.Migration

  # Null keeps the agent on the model configured in Settings > Agents; a value
  # overrides it for that agent only.
  def change do
    alter table(:agents) do
      add :model, :string
    end
  end
end
