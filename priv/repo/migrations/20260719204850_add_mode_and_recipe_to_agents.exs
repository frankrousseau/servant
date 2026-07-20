defmodule Servant.Repo.Migrations.AddModeAndRecipeToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :mode, :string, null: false, default: "prompt"
      add :recipe, :map
    end
  end
end
