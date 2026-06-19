defmodule Servant.Connectors.HyperEVM.TransactionParser do
  @moduledoc false
  # Kept for backward compatibility. Use Servant.Connectors.EVM.TransactionParser instead.
  defdelegate parse_transaction(tx, wallet, opts \\ []),
    to: Servant.Connectors.EVM.TransactionParser

  defdelegate parse_token_transfer(tx, wallet, opts \\ []),
    to: Servant.Connectors.EVM.TransactionParser
end
