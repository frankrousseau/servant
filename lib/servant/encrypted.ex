defmodule Servant.Encrypted do
  @moduledoc """
  AES-256-GCM encryption for data at rest (connector secrets).

  Payload layout: `"ENC1" <> iv(12) <> tag(16) <> ciphertext`. The magic prefix
  is also the GCM associated data. It also makes it possible to tell
  ciphertext from legacy plaintext JSON (which starts with `{` or `[`).

  The key comes (through SHA-256) from `:connector_encryption_key` if it is
  configured. If not, it comes from the endpoint `secret_key_base`. **If you
  change that secret, you cannot decrypt the existing connector secrets**:
  you must enter them again.
  """

  @magic "ENC1"

  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @magic, true)

    @magic <> iv <> tag <> ciphertext
  end

  def decrypt(<<"ENC1", iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @magic, tag, false) do
      :error -> :error
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_), do: :error

  def encrypted?(<<"ENC1", _::binary>>), do: true
  def encrypted?(_), do: false

  defp key do
    secret =
      Application.get_env(:servant, :connector_encryption_key) || endpoint_secret()

    :crypto.hash(:sha256, secret)
  end

  defp endpoint_secret do
    :servant
    |> Application.fetch_env!(ServantWeb.Endpoint)
    |> Keyword.get(:secret_key_base) ||
      raise "secret_key_base is not configured; cannot derive the connector encryption key"
  end
end
