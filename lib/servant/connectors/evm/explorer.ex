defmodule Servant.Connectors.EVM.Explorer do
  @moduledoc """
  Generic Etherscan/Blockscout-compatible API client for fetching
  transaction history on any EVM chain. Pass `chain_id:` and `api_key:`
  in `opts` for Etherscan V2 (`https://api.etherscan.io/v2/api`), which
  multiplexes every chain behind one URL and requires a (free) API key;
  Blockscout instances ignore both parameters.
  """

  alias Servant.Connectors.EVM.RateLimiter

  @page_size 1000
  @max_pages 50
  # Retries of an explorer "rate limit" answer (HTTP 200, so Req never sees
  # it): another client of the same key may still burst past our own pacing.
  @rate_limit_retries 3
  @rate_limit_backoff_ms 1_100

  def list_transactions(address, explorer_url, opts \\ []) do
    fetch_all_pages("txlist", address, explorer_url, opts)
  end

  def list_token_transfers(address, explorer_url, opts \\ []) do
    fetch_all_pages("tokentx", address, explorer_url, opts)
  end

  @doc false
  # Etherscan/Blockscout wrap everything in {status, message, result} over
  # HTTP 200: a list result is data (possibly empty), a binary result on
  # status "0" is an error message (deprecated endpoint, missing API key,
  # rate limit) and must fail the sync instead of passing for zero
  # transactions.
  def parse_body(%{"status" => "1", "result" => result}) when is_list(result), do: {:ok, result}
  def parse_body(%{"status" => "0", "result" => result}) when is_list(result), do: {:ok, []}

  def parse_body(%{"status" => "0", "result" => result}) when is_binary(result),
    do: {:error, result}

  def parse_body(%{"status" => "0"}), do: {:ok, []}
  def parse_body(body), do: {:error, %{status: 200, body: body}}

  defp fetch_all_pages(action, address, explorer_url, opts) do
    fetch_all_pages(action, address, explorer_url, opts, 1, [])
  end

  defp fetch_all_pages(_action, _address, _url, _opts, page, acc) when page > @max_pages do
    {:ok, acc}
  end

  defp fetch_all_pages(action, address, explorer_url, opts, page, acc) do
    params =
      %{
        module: "account",
        action: action,
        address: address,
        startblock: Keyword.get(opts, :start_block, 0),
        endblock: 99_999_999_999,
        page: page,
        offset: @page_size,
        sort: "asc"
      }
      |> maybe_put(:chainid, Keyword.get(opts, :chain_id))
      |> maybe_put(:apikey, Keyword.get(opts, :api_key))

    case request_paced(explorer_url, params, @rate_limit_retries) do
      {:ok, results} when is_list(results) and length(results) == @page_size ->
        fetch_all_pages(action, address, explorer_url, opts, page + 1, acc ++ results)

      {:ok, results} when is_list(results) ->
        {:ok, acc ++ results}

      {:error, _} = error ->
        if acc == [], do: error, else: {:ok, acc}
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  # One queue per API key (Etherscan V2 serves every chain from one URL and
  # counts calls per key), per explorer URL for keyless Blockscout instances.
  defp request_paced(url, params, retries_left) do
    RateLimiter.wait(params[:apikey] || url)

    case do_request(url, params) do
      {:error, message} when is_binary(message) and retries_left > 0 ->
        if rate_limited?(message) do
          Servant.HTTP.throttle(@rate_limit_backoff_ms)
          request_paced(url, params, retries_left - 1)
        else
          {:error, message}
        end

      result ->
        result
    end
  end

  @doc false
  def rate_limited?(message), do: String.match?(message, ~r/rate limit/i)

  # Retries (429, 5xx, transport errors) are Req's job: it backs off
  # exponentially and honors retry-after on safe methods.
  defp do_request(url, params) do
    case Req.get(url, Servant.HTTP.req_options(params: params)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
