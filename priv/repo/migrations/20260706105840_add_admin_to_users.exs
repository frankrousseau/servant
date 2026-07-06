defmodule Servant.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Operator flag: the first account created on a fresh instance gets it.
      # Gates the Audit page (server-wide stats + all users' access logs).
      add :admin, :boolean, default: false, null: false
    end

    # Existing single-user installs: the sole/earliest user is the operator.
    execute(
      """
      UPDATE users SET admin = 1
      WHERE id = (SELECT id FROM users ORDER BY inserted_at ASC, id ASC LIMIT 1)
      """,
      "SELECT 1"
    )
  end
end
