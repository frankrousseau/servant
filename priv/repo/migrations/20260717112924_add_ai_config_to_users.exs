defmodule Servant.Repo.Migrations.AddAiConfigToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :ai_config, :binary
    end
  end
end
