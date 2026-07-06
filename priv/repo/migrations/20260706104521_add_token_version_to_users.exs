defmodule Servant.Repo.Migrations.AddTokenVersionToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Embedded in the auth token; bumping it (logout, password change, TOTP
      # disable) invalidates every previously issued token for the user.
      add :token_version, :integer, default: 0, null: false
    end
  end
end
