defmodule Servant.Connectors.TxFormat do
  @moduledoc """
  Display helpers shared by the blockchain connectors (EVM chains and
  Solana) for rendering transfers: human titles, truncated addresses and
  fixed-point amount formatting.
  """

  @doc ~S"""
  Builds a transfer title such as `"Sent 1.5 ETH to 0xab..cd"`.

  `counterparty` should already be shortened (see `short_address/2`).
  """
  def transfer_title(direction, amount_display, symbol, counterparty) do
    "#{direction_label(direction)} #{amount_display} #{symbol} #{direction_preposition(direction)} #{counterparty}"
  end

  @doc "Human label for a transfer direction."
  def direction_label("received"), do: "Received"
  def direction_label(_), do: "Sent"

  @doc "Preposition linking a transfer to its counterparty."
  def direction_preposition("received"), do: "from"
  def direction_preposition(_), do: "to"

  @doc """
  Truncates an address to `head` leading and 4 trailing characters
  (e.g. `0xabcd..1234`). Short addresses are returned unchanged and `nil`
  becomes `"unknown"`.
  """
  def short_address(addr, head \\ 4)
  def short_address(nil, _head), do: "unknown"

  def short_address(addr, head) when byte_size(addr) > head + 4 do
    String.slice(addr, 0, head) <> ".." <> String.slice(addr, -4, 4)
  end

  def short_address(addr, _head), do: addr

  @doc """
  Formats a raw integer amount as a decimal string, dividing by `divisor`
  and trimming trailing zeros (e.g. `1_500_000_000, 1_000_000_000, 9` ->
  `"1.5"`).
  """
  def format_units(amount, divisor, decimals) do
    (amount / divisor)
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
