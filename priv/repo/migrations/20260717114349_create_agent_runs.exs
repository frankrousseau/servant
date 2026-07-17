defmodule Servant.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :action, :string, null: false
      add :app_id, :string
      add :status, :string, null: false
      add :model, :string, null: false
      add :prompt, :text
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :duration_ms, :integer
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:user_id, :inserted_at])
  end
end
