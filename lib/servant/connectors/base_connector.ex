defmodule Servant.Connectors.BaseConnector do
  @moduledoc """
  Connector for the wallet transactions of the **Base** chain (Coinbase L2).

  The name can mislead: this is **not** an abstract or base connector. It follows
  the `<ChainName>Connector` convention, as `ArbitrumConnector`,
  `EthereumConnector` and the other chain connectors do. The generic, reusable
  EVM implementation is in `Servant.Connectors.EVMConnector` (a `__using__`
  macro). This module is only a thin configuration of that implementation for
  the Base network.
  """

  use Servant.Connectors.EVMConnector,
    id: "base",
    name: "Base",
    chain: "base",
    chain_id: 8453,
    native_symbol: "ETH",
    default_explorer_url: "https://api.etherscan.io/v2/api"
end
