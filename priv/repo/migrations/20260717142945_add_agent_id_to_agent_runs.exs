defmodule Servant.Repo.Migrations.AddAgentIdToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agent_runs, [:agent_id])
  end
end
