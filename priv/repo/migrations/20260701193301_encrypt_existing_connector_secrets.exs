defmodule Servant.Repo.Migrations.EncryptExistingConnectorSecrets do
  use Ecto.Migration

  # Encrypt connector_configs.config rows that are still stored as plaintext
  # JSON. Idempotent: rows already encrypted (magic prefix) are skipped. Uses
  # raw SQL so it doesn't depend on the schema.

  def up do
    {:ok, %{rows: rows}} = repo().query("SELECT id, config FROM connector_configs", [])

    for [id, config] <- rows, is_binary(config), not Servant.Encrypted.encrypted?(config) do
      encrypted = Servant.Encrypted.encrypt(config)
      repo().query!("UPDATE connector_configs SET config = ? WHERE id = ?", [encrypted, id])
    end
  end

  def down do
    {:ok, %{rows: rows}} = repo().query("SELECT id, config FROM connector_configs", [])

    for [id, config] <- rows, is_binary(config), Servant.Encrypted.encrypted?(config) do
      {:ok, plaintext} = Servant.Encrypted.decrypt(config)
      repo().query!("UPDATE connector_configs SET config = ? WHERE id = ?", [plaintext, id])
    end
  end
end
