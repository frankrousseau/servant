defmodule Servant.Connectors.SolanaConnector do
  @moduledoc """
  Connector for Solana wallet transactions.
  Tracks SOL and SPL token transfers for a given wallet address
  using incremental sync via the last seen transaction signature.
  """

  use Servant.Connectors.Connector

  require Logger

  alias Servant.Connectors.Solana.{RPC, TransactionParser, TokenMetadata}

  @default_min_lamports 1_000_000
  @tx_fetch_delay_ms 1_000
  @sigs_per_page 1000
  @max_pages 10
  @max_consecutive_errors 3

  @impl true
  def id, do: "solana"

  @impl true
  def name, do: "Solana Wallet"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "blockchain_tx"

  @impl true
  def supported_schedules do
    ~w(on_demand every_5_minutes every_hour every_day every_week)
  end

  @impl true
  def default_schedule, do: "every_5_minutes"

  @impl true
  def init(_credentials, config) do
    case get_wallet_address(config) do
      nil ->
        {:error, :missing_wallet_address}

      address ->
        {:ok,
         %{
           wallet_address: address,
           rpc_url: Map.get(config, "rpc_url"),
           min_lamports: Map.get(config, "min_sol_amount", @default_min_lamports),
           last_signature: Map.get(config, "last_signature")
         }}
    end
  end

  @impl true
  def sync(state) do
    rpc_opts = if state.rpc_url, do: [rpc_url: state.rpc_url], else: []

    case fetch_all_signatures(state.wallet_address, state.last_signature, rpc_opts) do
      {:ok, []} ->
        {:ok, [], state}

      {:ok, all_signatures} ->
        # Process oldest-first for consistent state
        all_signatures = Enum.reverse(all_signatures)

        {entries, new_last_sig, _errors} =
          Enum.reduce_while(all_signatures, {[], state.last_signature, 0}, fn sig_info, {acc, last_sig, errors} ->
            signature = sig_info["signature"]

            # Skip failed transactions
            if sig_info["err"] != nil do
              {:cont, {acc, signature, errors}}
            else
              Process.sleep(@tx_fetch_delay_ms)

              case fetch_and_parse(signature, state, rpc_opts) do
                {:ok, entry} ->
                  {:cont, {[entry | acc], signature, 0}}

                :skip ->
                  {:cont, {acc, signature, 0}}

                {:error, reason} ->
                  Logger.warning("Failed to fetch tx #{signature}: #{inspect(reason)}")
                  # Don't advance last_signature past a failed fetch so we retry it next sync.
                  # Stop after too many consecutive errors to avoid hammering a failing RPC.
                  if errors + 1 >= @max_consecutive_errors do
                    {:halt, {acc, last_sig, errors + 1}}
                  else
                    {:cont, {acc, last_sig, errors + 1}}
                  end
              end
            end
          end)

        entries = Enum.reverse(entries)
        {:ok, entries, %{state | last_signature: new_last_sig}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Paginate through all signatures since last_signature
  defp fetch_all_signatures(address, last_signature, rpc_opts) do
    fetch_all_signatures(address, last_signature, rpc_opts, nil, [], 0)
  end

  defp fetch_all_signatures(_address, _last_sig, _rpc_opts, _before, acc, page)
       when page >= @max_pages do
    {:ok, acc}
  end

  defp fetch_all_signatures(address, last_signature, rpc_opts, before, acc, page) do
    opts =
      rpc_opts ++
        [limit: @sigs_per_page] ++
        if(last_signature, do: [until: last_signature], else: []) ++
        if(before, do: [before: before], else: [])

    case RPC.get_signatures(address, opts) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, signatures} ->
        new_acc = acc ++ signatures

        if length(signatures) < @sigs_per_page do
          # Last page
          {:ok, new_acc}
        else
          # More pages available — use the last signature as cursor
          last = List.last(signatures)
          Process.sleep(500)
          fetch_all_signatures(address, last_signature, rpc_opts, last["signature"], new_acc, page + 1)
        end

      {:error, reason} ->
        if acc == [] do
          {:error, reason}
        else
          # Return what we have
          {:ok, acc}
        end
    end
  end

  defp fetch_and_parse(signature, state, rpc_opts) do
    case RPC.get_transaction(signature, rpc_opts) do
      {:ok, nil} ->
        :skip

      {:ok, tx} ->
        case TransactionParser.parse(tx, state.wallet_address, min_lamports: state.min_lamports) do
          {:ok, parsed} ->
            {:ok, build_entry(parsed, state.wallet_address)}

          :skip ->
            :skip
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_entry(parsed, wallet_address) do
    # Resolve token symbols for SPL transfers
    spl_mints =
      parsed.transfers
      |> Enum.filter(&(&1.type == "spl" && &1.mint))
      |> Enum.map(& &1.mint)

    token_map = if spl_mints != [], do: TokenMetadata.resolve(spl_mints), else: %{}

    transfers =
      Enum.map(parsed.transfers, fn t ->
        symbol =
          case t.type do
            "sol" -> "SOL"
            "spl" -> get_in(token_map, [t.mint, "symbol"]) || t[:symbol] || "???"
          end

        Map.put(t, :symbol, symbol)
      end)

    title = build_title(transfers)
    counterparty = transfers |> Enum.map(& &1.counterparty) |> Enum.find(& &1)

    occurred_at =
      case parsed.block_time do
        ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
        _ -> DateTime.utc_now() |> DateTime.truncate(:second)
      end

    %{
      "kind" => "blockchain_tx",
      "source" => "solana",
      "external_id" => parsed.signature,
      "title" => title,
      "occurred_at" => occurred_at,
      "data" => %{
        "signature" => parsed.signature,
        "slot" => parsed.slot,
        "wallet" => wallet_address,
        "transfers" => transfers,
        "counterparty" => counterparty
      },
      "metadata" => %{}
    }
  end

  defp build_title([]), do: "Solana transaction"

  defp build_title(transfers) do
    transfer = List.first(transfers)
    counterparty_short = short_address(transfer.counterparty)

    dir = if transfer.direction == "received", do: "Received", else: "Sent"
    to_from = if transfer.direction == "received", do: "from", else: "to"

    "#{dir} #{transfer.amount_display} #{transfer.symbol} #{to_from} #{counterparty_short}"
  end

  defp short_address(nil), do: "unknown"

  defp short_address(addr) when byte_size(addr) > 8 do
    String.slice(addr, 0, 4) <> ".." <> String.slice(addr, -4, 4)
  end

  defp short_address(addr), do: addr

  defp get_wallet_address(config) do
    config_value(config, "wallet_address")
  end
end
