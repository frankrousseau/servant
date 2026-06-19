defmodule Servant.Connectors.BaseConnector do
  @moduledoc """
  Connector for Base (Coinbase L2) wallet transactions.
  """

  use Servant.Connectors.EVMConnector,
    id: "base",
    name: "Base",
    chain: "base",
    chain_id: 8453,
    native_symbol: "ETH",
    default_explorer_url: "https://api.basescan.org/api"
end
