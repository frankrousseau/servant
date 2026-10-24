defmodule Servant.Connectors.EthereumConnector do
  @moduledoc """
  Connector for the wallet transactions of the Ethereum mainnet.
  """

  use Servant.Connectors.EVMConnector,
    id: "ethereum",
    name: "Ethereum",
    chain: "ethereum",
    chain_id: 1,
    native_symbol: "ETH",
    default_explorer_url: "https://api.etherscan.io/v2/api"
end
