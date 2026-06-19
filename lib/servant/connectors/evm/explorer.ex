defmodule Servant.Connectors.EVM.Explorer do
  @moduledoc """
  Generic Etherscan/Blockscout-compatible API client for fetching
  transaction history on any EVM chain.
  """

  @max_retries 3
  @retry_delay_ms 1_000
  @page_size 1000
  @max_pages 50

  def list_transactions(address, explorer_url, opts \\ []) do
    fetch_all_pages("txlist", address, explorer_url, opts)
  end

  def list_token_transfers(address, explorer_url, opts \\ []) do
    fetch_all_pages("tokentx", address, explorer_url, opts)
  end

  defp fetch_all_pages(action, address, explorer_url, opts) do
    fetch_all_pages(action, address, explorer_url, opts, 1, [])
  end

  defp fetch_all_pages(_action, _address, _url, _opts, page, acc) when page > @max_pages do
    {:ok, acc}
  end

  defp fetch_all_pages(action, address, explorer_url, opts, page, acc) do
    params = %{
      module: "account",
      action: action,
      address: address,
      startblock: Keyword.get(opts, :start_block, 0),
      endblock: 99_999_999_999,
      page: page,
      offset: @page_size,
      sort: "asc"
    }

    case do_request(explorer_url, params, 0) do
      {:ok, results} when is_list(results) and length(results) == @page_size ->
        Process.sleep(200)
        fetch_all_pages(action, address, explorer_url, opts, page + 1, acc ++ results)

      {:ok, results} when is_list(results) ->
        {:ok, acc ++ results}

      {:error, _} = error ->
        if acc == [], do: error, else: {:ok, acc}
    end
  end

  defp do_request(url, params, attempt) do
    case Req.get(url, Servant.HTTP.req_options(params: params)) do
      {:ok, %Req.Response{status: 200, body: %{"status" => "1", "result" => result}}}
      when is_list(result) ->
        {:ok, result}

      {:ok,
       %Req.Response{status: 200, body: %{"status" => "0", "message" => "No transactions found"}}} ->
        {:ok, []}

      {:ok, %Req.Response{status: 200, body: %{"status" => "0"}}} ->
        {:ok, []}

      {:ok, %Req.Response{status: 429}} when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms * (attempt + 1))
        do_request(url, params, attempt + 1)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, _reason} when attempt < @max_retries ->
        Process.sleep(@retry_delay_ms * (attempt + 1))
        do_request(url, params, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
