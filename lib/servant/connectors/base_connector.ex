defmodule Servant.Connectors.BaseConnector do
  @moduledoc """
  Connector for the **Base** chain (Coinbase L2) wallet transactions.

  Despite the name, this is **not** an abstract/base connector; it follows the
  `<ChainName>Connector` convention shared with `ArbitrumConnector`,
  `EthereumConnector`, etc. The generic, reusable EVM implementation lives in
  `Servant.Connectors.EVMConnector` (a `__using__` macro); this module is just a
  thin configuration of it for the Base network.
  """

  use Servant.Connectors.EVMConnector,
    id: "base",
    name: "Base",
    chain: "base",
    chain_id: 8453,
    native_symbol: "ETH",
    default_explorer_url: "https://api.basescan.org/api"
end
