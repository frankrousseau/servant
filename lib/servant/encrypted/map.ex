defmodule Servant.Encrypted.Map do
  @moduledoc """
  Ecto type for a map field encrypted at rest via `Servant.Encrypted`.

  On `dump` the map is JSON-encoded then encrypted. On `load` it is decrypted
  and JSON-decoded; a value that isn't our ciphertext is treated as legacy
  plaintext JSON (so rows written before encryption still load, and get
  encrypted on their next write).
  """
  use Ecto.Type

  def type, do: :binary

  def cast(value) when is_map(value), do: {:ok, value}
  def cast(nil), do: {:ok, %{}}
  def cast(_), do: :error

  def dump(value) when is_map(value), do: {:ok, Servant.Encrypted.encrypt(Jason.encode!(value))}
  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  def load(nil), do: {:ok, %{}}

  def load(binary) when is_binary(binary) do
    case Servant.Encrypted.decrypt(binary) do
      {:ok, json} -> decode(json)
      # Legacy plaintext row (pre-encryption).
      :error -> decode(binary)
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      _ -> :error
    end
  end
end
