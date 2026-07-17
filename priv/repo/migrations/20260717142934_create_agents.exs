defmodule Servant.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prompt, :text, null: false
      add :kinds, {:array, :string}, null: false
      add :lookback_days, :integer, null: false, default: 7
      add :schedule, :string, null: false, default: "every_day"
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:user_id])
  end
end
