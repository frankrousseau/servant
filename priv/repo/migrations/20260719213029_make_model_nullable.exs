defmodule Servant.Repo.Migrations.MakeModelNullable do
  @moduledoc """
  Widens `agent_runs.model` to allow nil (recipe-mode agents don't set a model,
  only prompt-mode agents do). exqlite/ecto_sqlite3 does not support
  `ALTER COLUMN`, so this recreates the table instead.
  """

  use Ecto.Migration

  @columns "id, user_id, type, action, app_id, status, model, prompt, agent_id, input_tokens, output_tokens, duration_ms, error, inserted_at, updated_at"

  def up do
    create table(:agent_runs_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :action, :string, null: false
      add :app_id, :string
      add :status, :string, null: false
      add :model, :string
      add :prompt, :text
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :duration_ms, :integer
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO agent_runs_new (#{@columns}) SELECT #{@columns} FROM agent_runs"

    drop table(:agent_runs)
    rename table(:agent_runs_new), to: table(:agent_runs)

    create index(:agent_runs, [:user_id, :inserted_at])
    create index(:agent_runs, [:agent_id])
  end

  def down do
    create table(:agent_runs_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :action, :string, null: false
      add :app_id, :string
      add :status, :string, null: false
      add :model, :string, null: false
      add :prompt, :text
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :duration_ms, :integer
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    execute "INSERT INTO agent_runs_new (#{@columns}) SELECT #{@columns} FROM agent_runs"

    drop table(:agent_runs)
    rename table(:agent_runs_new), to: table(:agent_runs)

    create index(:agent_runs, [:user_id, :inserted_at])
    create index(:agent_runs, [:agent_id])
  end
end
