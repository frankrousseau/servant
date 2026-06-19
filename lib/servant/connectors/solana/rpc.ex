defmodule Servant.Connectors.Solana.RPC do
  @moduledoc """
  Thin JSON-RPC wrapper for Solana RPC endpoints.
  """

  @default_url "https://api.mainnet-beta.solana.com"
  @max_retries 5
  @retry_delay_ms 2_000

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

      # 429 in JSON body (HTTP 200 but RPC-level rate limit)
      {:ok, %Req.Response{status: 200, body: %{"error" => %{"code" => 429}}}}
      when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms * (attempt + 1))
        do_call(url, body, attempt + 1)

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, error}

      # HTTP-level 429
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
  Fetches confirmed transaction signatures for a wallet address.
  Options: :before (signature), :limit (default 100).
  """
  def get_signatures(address, opts \\ []) do
    config = %{limit: Keyword.get(opts, :limit, 100)}

    config =
      case Keyword.get(opts, :before) do
        nil -> config
        sig -> Map.put(config, :before, sig)
      end

    config =
      case Keyword.get(opts, :until) do
        nil -> config
        sig -> Map.put(config, :until, sig)
      end

    call("getSignaturesForAddress", [address, config], opts)
  end

  @doc """
  Fetches a parsed transaction by signature.
  """
  def get_transaction(signature, opts \\ []) do
    call(
      "getTransaction",
      [signature, %{encoding: "jsonParsed", maxSupportedTransactionVersion: 0}],
      opts
    )
  end
end
