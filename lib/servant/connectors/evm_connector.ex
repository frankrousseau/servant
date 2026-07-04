defmodule Servant.Connectors.EVMConnector do
  @moduledoc """
  Generic EVM chain connector. Use this macro to create a connector
  for any EVM chain with an Etherscan/Blockscout-compatible explorer API.

  The wallet address may be a `.eth` name (ENS, resolved on mainnet); it is
  resolved to the wallet address at sync time and cached for the worker's
  lifetime, so a re-pointed name is picked up on the next restart.

  ## Usage

      defmodule MyApp.Connectors.ArbitrumConnector do
        use Servant.Connectors.EVMConnector,
          id: "arbitrum",
          name: "Arbitrum",
          chain: "arbitrum",
          chain_id: 42161,
          native_symbol: "ETH",
          default_explorer_url: "https://api.arbiscan.io/api"
      end
  """

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    chain = Keyword.fetch!(opts, :chain)
    chain_id = Keyword.fetch!(opts, :chain_id)
    native_symbol = Keyword.fetch!(opts, :native_symbol)
    default_explorer_url = Keyword.fetch!(opts, :default_explorer_url)

    quote do
      use Servant.Connectors.Connector

      require Logger

      alias Servant.Connectors.EVM.{Explorer, TransactionParser}

      @default_min_wei 1_000_000_000_000_000

      @impl true
      def id, do: unquote(id)

      @impl true
      def name, do: unquote(name)

      @impl true
      def required_credentials, do: []

      @impl true
      def kind, do: "blockchain_tx"

      @impl true
      def supported_schedules, do: ~w(on_demand every_5_minutes every_hour every_day every_week)

      @impl true
      def default_schedule, do: "every_5_minutes"

      @impl true
      def init(_credentials, config) do
        case config_value(config, "wallet_address") do
          nil ->
            {:error, :missing_wallet_address}

          address ->
            {:ok,
             %{
               wallet_address: address,
               resolved_address: nil,
               explorer_url: config_value(config, "explorer_url", unquote(default_explorer_url)),
               min_wei: config_value(config, "min_wei", @default_min_wei),
               last_block: config_value(config, "last_block", 0)
             }}
        end
      end

      @impl true
      def persisted_config(state), do: %{"last_block" => state.last_block}

      @impl true
      def sync(state) do
        case resolve_wallet(state) do
          {:ok, state} -> do_sync(state)
          {:error, reason} -> {:error, reason, state}
        end
      end

      @doc false
      # Public for tests. Maps the configured address to the actual wallet
      # address: `.eth` names are resolved through ENS, plain addresses pass
      # through.
      def resolve_wallet(%{resolved_address: address} = state) when is_binary(address),
        do: {:ok, state}

      def resolve_wallet(%{wallet_address: address} = state) do
        if String.ends_with?(String.downcase(address), ".eth") do
          case Servant.Connectors.EVM.ENS.resolve(address) do
            {:ok, resolved} -> {:ok, %{state | resolved_address: resolved}}
            {:error, reason} -> {:error, {:ens_resolution_failed, reason}}
          end
        else
          {:ok, %{state | resolved_address: address}}
        end
      end

      defp do_sync(state) do
        start_block = state.last_block + 1

        with {:ok, txs} <-
               Explorer.list_transactions(state.resolved_address, state.explorer_url,
                 start_block: start_block
               ),
             {:ok, token_txs} <-
               Explorer.list_token_transfers(state.resolved_address, state.explorer_url,
                 start_block: start_block
               ) do
          native_entries =
            Enum.flat_map(txs, fn tx ->
              case TransactionParser.parse_transaction(tx, state.resolved_address,
                     min_wei: state.min_wei
                   ) do
                {:ok, parsed} -> [build_entry(parsed, state.resolved_address)]
                _ -> []
              end
            end)

          token_entries =
            Enum.flat_map(token_txs, fn tx ->
              case TransactionParser.parse_token_transfer(tx, state.resolved_address) do
                {:ok, parsed} -> [build_entry(parsed, state.resolved_address)]
                _ -> []
              end
            end)

          all_entries = native_entries ++ token_entries

          new_last_block =
            (txs ++ token_txs)
            |> Enum.map(&parse_block_number/1)
            |> Enum.max(fn -> state.last_block end)

          {:ok, all_entries, %{state | last_block: new_last_block}}
        else
          {:error, reason} ->
            {:error, reason, state}
        end
      end

      defp build_entry(parsed, wallet_address) do
        transfer = List.first(parsed.transfers)
        title = build_title(transfer)

        %{
          "kind" => "blockchain_tx",
          "source" => unquote(chain),
          "external_id" => external_id(parsed, transfer),
          "title" => title,
          "occurred_at" => parsed.timestamp,
          "data" => %{
            "tx_hash" => parsed.tx_hash,
            "block_number" => parsed.block_number,
            "wallet" => wallet_address,
            "chain" => unquote(chain),
            "chain_id" => unquote(chain_id),
            "transfers" => parsed.transfers,
            "counterparty" => transfer.counterparty
          },
          "metadata" => %{}
        }
      end

      # Native transfers are one-per-tx, so hash+type is unique. ERC-20 transfers
      # can be many-per-tx; disambiguate with the log index (falling back to the
      # token address so identical-token multi-transfers still differ).
      defp external_id(%{log_index: log_index} = parsed, transfer)
           when not is_nil(log_index) do
        "#{parsed.tx_hash}-#{transfer.type}-#{log_index}"
      end

      defp external_id(parsed, %{token_address: token_address} = transfer)
           when not is_nil(token_address) do
        "#{parsed.tx_hash}-#{transfer.type}-#{token_address}"
      end

      defp external_id(parsed, transfer), do: "#{parsed.tx_hash}-#{transfer.type}"

      defp build_title(nil), do: "#{unquote(name)} transaction"

      defp build_title(transfer) do
        symbol = if transfer.type == "native", do: unquote(native_symbol), else: transfer.symbol
        counterparty_short = Servant.Connectors.TxFormat.short_address(transfer.counterparty, 6)

        Servant.Connectors.TxFormat.transfer_title(
          transfer.direction,
          transfer.amount_display,
          symbol,
          counterparty_short
        )
      end

      defp parse_block_number(%{"blockNumber" => bn}) when is_binary(bn) do
        case Integer.parse(bn) do
          {n, _} -> n
          :error -> 0
        end
      end

      defp parse_block_number(_), do: 0

      defoverridable init: 2, sync: 1
    end
  end
end
