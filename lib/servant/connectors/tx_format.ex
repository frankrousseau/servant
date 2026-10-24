defmodule Servant.Connectors.TxFormat do
  @moduledoc """
  Display helpers that the blockchain connectors (EVM chains and Solana)
  share to render transfers: human titles, truncated addresses and the
  format of fixed-point amounts.
  """

  @doc ~S"""
  Builds a transfer title such as `"Sent 1.5 ETH to 0xab..cd"`.

  `counterparty` must already be shortened (see `short_address/2`).
  """
  def transfer_title(direction, amount_display, symbol, counterparty) do
    "#{direction_label(direction)} #{amount_display} #{symbol} #{direction_preposition(direction)} #{counterparty}"
  end

  @doc "Human label for a transfer direction."
  def direction_label("received"), do: "Received"
  def direction_label(_), do: "Sent"

  @doc "Preposition that links a transfer to its counterparty."
  def direction_preposition("received"), do: "from"
  def direction_preposition(_), do: "to"

  @doc """
  Truncates an address to its first `head` characters and its last 4
  characters (for example `0xabcd..1234`). Returns short addresses unchanged,
  and `nil` becomes `"unknown"`.
  """
  def short_address(addr, head \\ 4)
  def short_address(nil, _head), do: "unknown"

  def short_address(addr, head) when byte_size(addr) > head + 4 do
    String.slice(addr, 0, head) <> ".." <> String.slice(addr, -4, 4)
  end

  def short_address(addr, _head), do: addr

  @doc """
  Formats a raw integer amount as a decimal string. Divides the amount by
  `divisor` and trims the zeros at the end (for example
  `1_500_000_000, 1_000_000_000, 9` -> `"1.5"`).
  """
  def format_units(amount, divisor, decimals)
      when is_integer(amount) and is_integer(divisor) and divisor > 0 do
    # Integer arithmetic only. Float division loses precision after ~15 digits,
    # and that is important for wei amounts with 18 decimals.
    scale = byte_size(Integer.to_string(divisor)) - 1
    sign = if amount < 0, do: "-", else: ""
    abs_amount = abs(amount)

    whole = div(abs_amount, divisor)

    frac =
      abs_amount
      |> rem(divisor)
      |> Integer.to_string()
      |> String.pad_leading(scale, "0")
      |> String.slice(0, decimals)
      |> String.trim_trailing("0")

    case frac do
      "" -> "#{sign}#{whole}"
      f -> "#{sign}#{whole}.#{f}"
    end
  end
end
