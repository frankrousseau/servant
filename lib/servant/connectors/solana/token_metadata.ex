defmodule Servant.Connectors.Solana.TokenMetadata do
  @moduledoc """
  Resolves the mint addresses of SPL tokens to a name and a symbol with the strict token list
  of Jupiter. The module caches the results in connector_environment with a TTL of 24 hours.
  """

  alias Servant.Connectors

  @connector_type "solana"
  @namespace "token_metadata"
  @ttl_seconds 86_400
  @jupiter_url "https://token.jup.ag/strict"

  @doc """
  Resolves a list of mint addresses to `%{mint => %{symbol, name}}`.
  Reads the cache first, then fetches the missing mints from Jupiter in bulk.
  """
  def resolve(mints) when is_list(mints) do
    {cached, missing} =
      mints
      |> Enum.uniq()
      |> Enum.reduce({%{}, []}, fn mint, {cached, missing} ->
        case Connectors.get_env(@connector_type, @namespace, mint) do
          %{"data" => data} -> {Map.put(cached, mint, data), missing}
          _ -> {cached, [mint | missing]}
        end
      end)

    Map.merge(cached, fetch_missing(missing))
  end

  @doc "Resolves a single mint. The fallback is a shortened mint address."
  def resolve_one(mint) do
    Map.get(resolve([mint]), mint, unknown(mint))
  end

  defp fetch_missing([]), do: %{}

  defp fetch_missing(mints) do
    case fetch_jupiter_list() do
      {:ok, tokens} ->
        token_map = Map.new(tokens, fn token -> {token["address"], token} end)
        Map.new(mints, fn mint -> {mint, cache(mint, Map.get(token_map, mint))} end)

      # Without the list, there is nothing to cache. Use a short mint as the
      # fallback and retry on the next sync.
      {:error, _reason} ->
        Map.new(mints, fn mint -> {mint, unknown(mint)} end)
    end
  end

  defp cache(mint, nil), do: unknown(mint)

  defp cache(mint, token) do
    data = %{"symbol" => token["symbol"], "name" => token["name"]}

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@ttl_seconds, :second)
      |> DateTime.truncate(:second)

    Connectors.put_env(@connector_type, @namespace, mint, %{"data" => data}, expires_at)
    data
  end

  defp unknown(mint), do: %{"symbol" => short_mint(mint), "name" => "Unknown token"}

  defp fetch_jupiter_list do
    case Req.get(@jupiter_url, Servant.HTTP.req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp short_mint(mint) when byte_size(mint) > 8 do
    String.slice(mint, 0, 4) <> ".." <> String.slice(mint, -4, 4)
  end

  defp short_mint(mint), do: mint
end
