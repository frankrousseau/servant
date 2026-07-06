defmodule Servant.Repo.Migrations.AddTotpToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # AES-256-GCM ciphertext of the TOTP secret (Servant.Encrypted).
      add :totp_secret, :binary
      # Timestamp of the last accepted code, to refuse replays in the window.
      add :totp_last_used_at, :utc_datetime
    end
  end
end
