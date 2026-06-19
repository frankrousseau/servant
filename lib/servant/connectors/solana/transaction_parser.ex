defmodule Servant.Connectors.Solana.TransactionParser do
  @moduledoc """
  Extracts balance changes from raw Solana transactions.
  Returns structured transfer data for a given wallet address.
  """

  @lamports_per_sol 1_000_000_000

  @doc """
  Parses a transaction for balance changes relevant to `wallet_address`.

  Returns `{:ok, parsed}` with transfer details or `:skip` if the transaction
  is failed, has no relevant changes, or changes are below the threshold.

  Options:
    - `:min_lamports` — minimum SOL change in lamports to include (default 1_000_000 = 0.001 SOL)
  """
  def parse(tx, wallet_address, opts \\ []) do
    min_lamports = Keyword.get(opts, :min_lamports, 1_000_000)

    with :ok <- check_success(tx),
         {:ok, account_index} <- find_account_index(tx, wallet_address),
         transfers when transfers != [] <-
           extract_transfers(tx, wallet_address, account_index, min_lamports) do
      {:ok,
       %{
         signature: get_in(tx, ["transaction", "signatures"]) |> List.first(),
         slot: tx["slot"],
         block_time: tx["blockTime"],
         transfers: transfers
       }}
    else
      :failed -> :skip
      {:error, :not_found} -> :skip
      [] -> :skip
    end
  end

  defp check_success(%{"meta" => %{"err" => nil}}), do: :ok
  defp check_success(%{"meta" => %{"err" => _}}), do: :failed
  defp check_success(_), do: :failed

  defp find_account_index(tx, wallet_address) do
    keys =
      get_in(tx, ["transaction", "message", "accountKeys"])
      |> List.wrap()

    index =
      Enum.find_index(keys, fn
        %{"pubkey" => pubkey} -> pubkey == wallet_address
        key when is_binary(key) -> key == wallet_address
      end)

    case index do
      nil -> {:error, :not_found}
      i -> {:ok, i}
    end
  end

  defp extract_transfers(tx, wallet_address, account_index, min_lamports) do
    sol_transfers = extract_sol_transfer(tx, wallet_address, account_index, min_lamports)
    spl_transfers = extract_spl_transfers(tx, wallet_address)

    sol_transfers ++ spl_transfers
  end

  defp extract_sol_transfer(tx, _wallet_address, account_index, min_lamports) do
    meta = tx["meta"]
    pre = Enum.at(meta["preBalances"] || [], account_index, 0)
    post = Enum.at(meta["postBalances"] || [], account_index, 0)
    diff = post - pre

    if abs(diff) < min_lamports do
      []
    else
      account_keys =
        get_in(tx, ["transaction", "message", "accountKeys"])
        |> List.wrap()

      counterparty = find_sol_counterparty(meta, account_keys, account_index, diff)

      direction = if diff > 0, do: "received", else: "sent"

      [
        %{
          type: "sol",
          direction: direction,
          amount: abs(diff),
          amount_display: format_sol(abs(diff)),
          symbol: "SOL",
          mint: nil,
          counterparty: counterparty
        }
      ]
    end
  end

  defp find_sol_counterparty(meta, account_keys, my_index, diff) do
    pre_balances = meta["preBalances"] || []
    post_balances = meta["postBalances"] || []

    # Find the account with the opposite balance change
    pre_balances
    |> Enum.zip(post_balances)
    |> Enum.with_index()
    |> Enum.find_value(fn {{pre, post}, idx} ->
      if idx != my_index do
        other_diff = post - pre

        # Opposite direction and similar magnitude
        if diff > 0 and other_diff < 0, do: pubkey_at(account_keys, idx)
        if diff < 0 and other_diff > 0, do: pubkey_at(account_keys, idx)
      end
    end)
  end

  defp extract_spl_transfers(tx, wallet_address) do
    meta = tx["meta"]
    pre_tokens = meta["preTokenBalances"] || []
    post_tokens = meta["postTokenBalances"] || []

    # Build a map of {mint, owner} => {pre_amount, post_amount}
    pre_map = token_balance_map(pre_tokens)
    post_map = token_balance_map(post_tokens)

    all_keys = Map.keys(pre_map) ++ Map.keys(post_map)
    all_keys = Enum.uniq(all_keys)

    all_keys
    |> Enum.filter(fn {_mint, owner} -> owner == wallet_address end)
    |> Enum.flat_map(fn {mint, _owner} = key ->
      pre_amount = parse_token_amount(Map.get(pre_map, key))
      post_amount = parse_token_amount(Map.get(post_map, key))
      diff = post_amount - pre_amount

      if diff == 0.0 do
        []
      else
        counterparty = find_spl_counterparty(pre_map, post_map, mint, wallet_address, diff)
        direction = if diff > 0, do: "received", else: "sent"

        decimals =
          (Map.get(post_map, key) || Map.get(pre_map, key))
          |> get_decimals()

        [
          %{
            type: "spl",
            direction: direction,
            amount: abs(diff),
            amount_display: Float.to_string(abs(diff)),
            symbol: nil,
            mint: mint,
            decimals: decimals,
            counterparty: counterparty
          }
        ]
      end
    end)
  end

  defp token_balance_map(token_balances) do
    Enum.reduce(token_balances, %{}, fn tb, acc ->
      mint = tb["mint"]
      owner = get_in(tb, ["owner"])

      if mint && owner do
        Map.put(acc, {mint, owner}, tb)
      else
        acc
      end
    end)
  end

  defp parse_token_amount(nil), do: 0.0

  defp parse_token_amount(tb) do
    case get_in(tb, ["uiTokenAmount", "uiAmount"]) do
      nil -> 0.0
      amount when is_number(amount) -> amount / 1
      _ -> 0.0
    end
  end

  defp get_decimals(nil), do: 0

  defp get_decimals(tb) do
    get_in(tb, ["uiTokenAmount", "decimals"]) || 0
  end

  defp find_spl_counterparty(pre_map, post_map, mint, my_address, my_diff) do
    all_keys = Map.keys(pre_map) ++ Map.keys(post_map)

    Enum.find_value(Enum.uniq(all_keys), fn
      {^mint, owner} when owner != my_address ->
        pre = parse_token_amount(Map.get(pre_map, {mint, owner}))
        post = parse_token_amount(Map.get(post_map, {mint, owner}))
        other_diff = post - pre

        if (my_diff > 0 and other_diff < 0) or (my_diff < 0 and other_diff > 0) do
          owner
        end

      _ ->
        nil
    end)
  end

  defp pubkey_at(account_keys, index) do
    case Enum.at(account_keys, index) do
      %{"pubkey" => pubkey} -> pubkey
      key when is_binary(key) -> key
      _ -> nil
    end
  end

  defp format_sol(lamports) do
    Servant.Connectors.TxFormat.format_units(lamports, @lamports_per_sol, 9)
  end
end
