defmodule Servant.Repo.Migrations.AddRunAtHourToAgents do
  use Ecto.Migration

  # Hour of the day (0-23, in the user's timezone) a daily or weekly agent
  # fires at. Null keeps the old behaviour: the interval counted from the
  # previous run, whenever that happened to be.
  def change do
    alter table(:agents) do
      add :run_at_hour, :integer
    end
  end
end
