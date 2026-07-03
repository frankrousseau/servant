defmodule Servant.Connectors.HyperEVM.RPC do
  @moduledoc """
  Standard EVM JSON-RPC wrapper for HyperEVM.
  """

  @default_url "https://rpc.hyperliquid.xyz/evm"
  @max_retries 3
  @retry_delay_ms 1_000

  def call(method, params, opts \\ []) do
    url = Keyword.get(opts, :rpc_url, @default_url)

    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: method,
      params: params
    }

    do_call(url, body, 0)
  end

  defp do_call(url, body, attempt) do
    case Req.post(url, Servant.HTTP.req_options(json: body)) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %Req.Response{status: 429}} when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms * (attempt + 1))
        do_call(url, body, attempt + 1)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, _reason} when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms * (attempt + 1))
        do_call(url, body, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the current block number as an integer.
  """
  def get_block_number(opts \\ []) do
    case call("eth_blockNumber", [], opts) do
      {:ok, hex} -> {:ok, hex_to_int(hex)}
      error -> error
    end
  end

  @doc """
  Gets a transaction receipt by hash.
  """
  def get_transaction_receipt(tx_hash, opts \\ []) do
    call("eth_getTransactionReceipt", [tx_hash], opts)
  end

  @doc """
  Gets a transaction by hash.
  """
  def get_transaction(tx_hash, opts \\ []) do
    call("eth_getTransactionByHash", [tx_hash], opts)
  end

  def hex_to_int("0x" <> hex), do: hex_to_int(hex)
  def hex_to_int(n) when is_integer(n), do: n

  def hex_to_int(hex) when is_binary(hex) do
    # Tolerate empty/malformed hex ("0x", non-hex chars) instead of raising.
    case Integer.parse(hex, 16) do
      {n, _rest} -> n
      :error -> 0
    end
  end
end
