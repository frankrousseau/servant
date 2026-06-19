defmodule Servant.Connectors.HyperEVM.Explorer do
  @moduledoc false
  # Kept for backward compatibility. Use Servant.Connectors.EVM.Explorer instead.
  defdelegate list_transactions(address, url, opts \\ []), to: Servant.Connectors.EVM.Explorer
  defdelegate list_token_transfers(address, url, opts \\ []), to: Servant.Connectors.EVM.Explorer
end
