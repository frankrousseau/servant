defmodule Servant.Connectors.ArbitrumConnector do
  @moduledoc """
  Connector for Arbitrum One wallet transactions.
  """

  use Servant.Connectors.EVMConnector,
    id: "arbitrum",
    name: "Arbitrum",
    chain: "arbitrum",
    chain_id: 42161,
    native_symbol: "ETH",
    default_explorer_url: "https://api.etherscan.io/v2/api"
end
