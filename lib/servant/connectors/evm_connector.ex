defmodule Servant.Connectors.EVMConnector do
  @moduledoc """
  Generic EVM chain connector. Use this macro to create a connector
  for any EVM chain with an Etherscan/Blockscout-compatible explorer API.

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
               explorer_url: config_value(config, "explorer_url", unquote(default_explorer_url)),
               min_wei: Map.get(config, "min_wei", @default_min_wei),
               last_block: Map.get(config, "last_block", 0)
             }}
        end
      end

      @impl true
      def sync(state) do
        start_block = state.last_block + 1

        with {:ok, txs} <- Explorer.list_transactions(state.wallet_address, state.explorer_url, start_block: start_block),
             {:ok, token_txs} <- Explorer.list_token_transfers(state.wallet_address, state.explorer_url, start_block: start_block) do
          native_entries =
            Enum.flat_map(txs, fn tx ->
              case TransactionParser.parse_transaction(tx, state.wallet_address, min_wei: state.min_wei) do
                {:ok, parsed} -> [build_entry(parsed, state.wallet_address)]
                _ -> []
              end
            end)

          token_entries =
            Enum.flat_map(token_txs, fn tx ->
              case TransactionParser.parse_token_transfer(tx, state.wallet_address) do
                {:ok, parsed} -> [build_entry(parsed, state.wallet_address)]
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
          "external_id" => "#{parsed.tx_hash}-#{transfer.type}",
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

      defoverridable [init: 2, sync: 1]
    end
  end
end
