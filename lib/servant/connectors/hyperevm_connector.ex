defmodule Servant.Connectors.HyperEVMConnector do
  @moduledoc """
  Connector for HyperEVM (Hyperliquid's EVM) wallet transactions.
  """

  use Servant.Connectors.EVMConnector,
    id: "hyperevm",
    name: "HyperEVM",
    chain: "hyperevm",
    chain_id: 999,
    native_symbol: "HYPE",
    default_explorer_url: "https://www.hyperscan.com/api"
end
