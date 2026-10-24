defmodule Servant.Encrypted.Map do
  @moduledoc """
  Ecto type for a map field encrypted at rest through `Servant.Encrypted`.

  On `dump`, the type JSON-encodes the map and then encrypts it. On `load`,
  the type decrypts the value and JSON-decodes it. If a value is not our
  ciphertext, the type reads it as legacy plaintext JSON. As a result, the
  rows written before encryption still load, and their next write encrypts
  them.
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
