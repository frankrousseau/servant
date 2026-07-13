defmodule Servant.Repo.Migrations.AddEnabledAppsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # null means "the default set" (see Servant.Accounts.User), so future
      # default changes apply to accounts that never touched the toggles.
      add :enabled_apps, {:array, :string}
    end
  end
end
