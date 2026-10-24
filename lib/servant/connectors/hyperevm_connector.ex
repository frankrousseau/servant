defmodule Servant.Connectors.HyperEVMConnector do
  @moduledoc """
  Connector for the wallet transactions of HyperEVM (the EVM of Hyperliquid).
  """

  use Servant.Connectors.EVMConnector,
    id: "hyperevm",
    name: "HyperEVM",
    chain: "hyperevm",
    chain_id: 999,
    native_symbol: "HYPE",
    default_explorer_url: "https://api.etherscan.io/v2/api"
end
