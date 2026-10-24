defmodule Servant.Connectors.SolanaConnector do
  @moduledoc """
  Connector for Solana wallet transactions.
  Tracks the SOL and SPL token transfers for a given wallet address.
  Uses an incremental sync through the signature of the last seen transaction.

  The wallet address can be a `.sol` domain (Solana Name Service). The
  connector resolves it to the pubkey of the owner at sync time and caches the
  result for the lifetime of the worker. As a result, the next restart picks
  up a domain that points to a new pubkey.
  """

  use Servant.Connectors.Connector

  require Logger

  alias Servant.Connectors.Solana.{RPC, TransactionParser, TokenMetadata}
  alias Servant.Connectors.TxFormat

  @default_min_lamports 1_000_000
  @tx_fetch_delay_ms 1_000
  @sigs_per_page 1000
  @max_pages 10
  # Cap the transactions processed per sync. At ~1s/tx (rate-limit throttling),
  # an unbounded backfill blocks the worker GenServer for many minutes. The
  # persisted `last_signature` cursor lets the next scheduled sync continue.
  @max_tx_per_sync 50

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
           resolved_address: nil,
           rpc_url: Map.get(config, "rpc_url"),
           min_lamports: Map.get(config, "min_sol_amount", @default_min_lamports),
           last_signature: Map.get(config, "last_signature")
         }}
    end
  end

  @impl true
  def persisted_config(state), do: %{"last_signature" => state.last_signature}

  @impl true
  def sync(state) do
    case resolve_wallet(state) do
      {:ok, state} -> do_sync(state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc false
  # Public for tests. Maps the configured address to the real wallet pubkey.
  # SNS resolves the `.sol` domains. Plain addresses pass through.
  def resolve_wallet(%{resolved_address: address} = state) when is_binary(address),
    do: {:ok, state}

  def resolve_wallet(%{wallet_address: address} = state) do
    if String.ends_with?(String.downcase(address), ".sol") do
      case resolve_sol_domain(address) do
        {:ok, resolved} -> {:ok, %{state | resolved_address: resolved}}
        {:error, reason} -> {:error, {:sns_resolution_failed, reason}}
      end
    else
      {:ok, %{state | resolved_address: address}}
    end
  end

  # ponytail: resolves through the public SNS SDK proxy (one GET, no crypto).
  # Change to on-chain PDA derivation through the RPC if the proxy goes away.
  # The old sns-sdk-proxy.bonfida.workers.dev host died with a Cloudflare
  # 1042 page when SNS moved from Bonfida to sns.id.
  defp resolve_sol_domain(domain) do
    url = "https://sdk-proxy.sns.id/resolve/#{URI.encode(domain)}"

    case Req.get(url, Servant.HTTP.req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"s" => "ok", "result" => address}}} ->
        {:ok, address}

      {:ok, %Req.Response{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_sync(state) do
    rpc_opts = if state.rpc_url, do: [rpc_url: state.rpc_url], else: []

    case fetch_all_signatures(state.resolved_address, state.last_signature, rpc_opts) do
      {:ok, []} ->
        {:ok, [], state}

      {:ok, all_signatures} ->
        # Process the oldest first for a consistent state. Bound the count per
        # sync so that a large backfill does not block the worker for ~1s/tx.
        all_signatures = all_signatures |> Enum.reverse() |> Enum.take(@max_tx_per_sync)

        {entries, new_last_sig, _errors} =
          Enum.reduce_while(all_signatures, {[], state.last_signature, 0}, fn sig_info,
                                                                              {acc, last_sig,
                                                                               errors} ->
            signature = sig_info["signature"]

            # Skip failed transactions.
            if sig_info["err"] != nil do
              {:cont, {acc, signature, errors}}
            else
              Servant.HTTP.throttle(@tx_fetch_delay_ms)

              case fetch_and_parse(signature, state, rpc_opts) do
                {:ok, entry} ->
                  {:cont, {[entry | acc], signature, 0}}

                :skip ->
                  {:cont, {acc, signature, 0}}

                {:error, reason} ->
                  Logger.warning("Failed to fetch tx #{signature}: #{inspect(reason)}")
                  # Halt at the first fetch error and keep the cursor at the last
                  # signature processed successfully. If the loop continues, a
                  # later success moves last_signature *past* this failed tx. The
                  # next sync queries only the signatures newer than the cursor,
                  # so it never fetches this tx again. The result is a silent,
                  # permanent data loss.
                  {:halt, {acc, last_sig, errors + 1}}
              end
            end
          end)

        entries = Enum.reverse(entries)
        {:ok, entries, %{state | last_signature: new_last_sig}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Paginate through all the signatures after last_signature.
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
          # More pages are available. Use the last signature as the cursor.
          last = List.last(signatures)
          Servant.HTTP.throttle(500)

          fetch_all_signatures(
            address,
            last_signature,
            rpc_opts,
            last["signature"],
            new_acc,
            page + 1
          )
        end

      {:error, reason} ->
        if acc == [] do
          {:error, reason}
        else
          # Return what we have.
          {:ok, acc}
        end
    end
  end

  defp fetch_and_parse(signature, state, rpc_opts) do
    case RPC.get_transaction(signature, rpc_opts) do
      {:ok, nil} ->
        :skip

      {:ok, tx} ->
        case TransactionParser.parse(tx, state.resolved_address, min_lamports: state.min_lamports) do
          {:ok, parsed} ->
            {:ok, build_entry(parsed, state.resolved_address)}

          :skip ->
            :skip
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_entry(parsed, wallet_address) do
    # Resolve the token symbols for the SPL transfers.
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
        ts when is_integer(ts) -> DateTime.truncate(DateTime.from_unix!(ts), :second)
        _ -> DateTime.truncate(DateTime.utc_now(), :second)
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
    counterparty_short = TxFormat.short_address(transfer.counterparty)

    TxFormat.transfer_title(
      transfer.direction,
      transfer.amount_display,
      transfer.symbol,
      counterparty_short
    )
  end

  defp get_wallet_address(config) do
    config_value(config, "wallet_address")
  end
end
