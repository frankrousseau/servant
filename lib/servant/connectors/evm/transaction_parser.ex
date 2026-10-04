defmodule Servant.Connectors.EVM.TransactionParser do
  @moduledoc """
  Parses EVM transactions and token transfers into a unified format
  for a given wallet address. Works with any Etherscan-compatible API response.
  """

  @native_decimals 18
  @wei_per_unit trunc(:math.pow(10, @native_decimals))

  @doc """
  Parses a native-currency transaction from an Etherscan-compatible
  txlist response.

  Returns `{:ok, parsed}`. Returns `:skip` if the transaction failed,
  has zero value, or is below the threshold.

  Options:
    - `:min_wei`: the minimum transfer, in wei, to include (default 1_000_000_000_000_000 = 0.001)
    - `:symbol`: the native currency symbol of the chain (default "ETH")
  """
  def parse_transaction(tx, wallet_address, opts \\ []) do
    min_wei = Keyword.get(opts, :min_wei, 1_000_000_000_000_000)

    with :ok <- check_success(tx),
         {:ok, value} <- parse_value(tx),
         true <- value >= min_wei do
      from = String.downcase(tx["from"] || "")
      to = String.downcase(tx["to"] || "")
      wallet_lower = String.downcase(wallet_address)

      direction =
        cond do
          from == wallet_lower and to == wallet_lower -> "self"
          from == wallet_lower -> "sent"
          to == wallet_lower -> "received"
          true -> "unknown"
        end

      if direction == "self" or direction == "unknown" do
        :skip
      else
        counterparty = if direction == "sent", do: tx["to"], else: tx["from"]

        {:ok,
         %{
           tx_hash: tx["hash"],
           block_number: parse_int(tx["blockNumber"]),
           timestamp: parse_timestamp(tx["timeStamp"]),
           transfers: [
             %{
               type: "native",
               direction: direction,
               amount: value,
               amount_display: format_native(value),
               symbol: Keyword.get(opts, :symbol, "ETH"),
               token_address: nil,
               decimals: @native_decimals,
               counterparty: counterparty
             }
           ]
         }}
      end
    else
      _ -> :skip
    end
  end

  @doc """
  Parses an ERC-20 token transfer from Blockscout's tokentx response.

  Returns `{:ok, parsed}` or `:skip`.
  """
  def parse_token_transfer(tx, wallet_address, _opts \\ []) do
    from = String.downcase(tx["from"] || "")
    to = String.downcase(tx["to"] || "")
    wallet_lower = String.downcase(wallet_address)

    direction =
      cond do
        from == wallet_lower and to == wallet_lower -> "self"
        from == wallet_lower -> "sent"
        to == wallet_lower -> "received"
        true -> "unknown"
      end

    if direction in ["self", "unknown"] do
      :skip
    else
      value = parse_int(tx["value"])
      decimals = parse_int(tx["tokenDecimal"] || "18")
      counterparty = if direction == "sent", do: tx["to"], else: tx["from"]

      amount_display =
        if decimals > 0 do
          (value / :math.pow(10, decimals))
          |> :erlang.float_to_binary(decimals: min(decimals, 8))
          |> String.trim_trailing("0")
          |> String.trim_trailing(".")
        else
          Integer.to_string(value)
        end

      {:ok,
       %{
         tx_hash: tx["hash"],
         block_number: parse_int(tx["blockNumber"]),
         timestamp: parse_timestamp(tx["timeStamp"]),
         # The tokentx rows of Etherscan contain a per-tx `logIndex`. Keep it.
         # Then a tx that emits several ERC-20 Transfer events gives distinct
         # external_ids. Without it, the events collide on the shared hash and
         # the dedup removes them.
         log_index: tx["logIndex"],
         transfers: [
           %{
             type: "erc20",
             direction: direction,
             amount: value,
             amount_display: amount_display,
             symbol: tx["tokenSymbol"] || "???",
             token_address: tx["contractAddress"],
             token_name: tx["tokenName"],
             decimals: decimals,
             counterparty: counterparty
           }
         ]
       }}
    end
  end

  defp check_success(%{"isError" => "0"}), do: :ok
  defp check_success(%{"isError" => "1"}), do: :failed
  # Token transfers do not have isError. Assume success.
  defp check_success(%{"tokenSymbol" => _}), do: :ok
  defp check_success(_), do: :ok

  defp parse_value(%{"value" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {v, _} when v > 0 -> {:ok, v}
      {0, _} -> {:ok, 0}
      _ -> :skip
    end
  end

  defp parse_value(_), do: :skip

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: 0

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {unix, _} -> DateTime.truncate(DateTime.from_unix!(unix), :second)
      :error -> DateTime.truncate(DateTime.utc_now(), :second)
    end
  end

  defp parse_timestamp(_), do: DateTime.truncate(DateTime.utc_now(), :second)

  defp format_native(wei) do
    Servant.Connectors.TxFormat.format_units(wei, @wei_per_unit, 8)
  end
end
