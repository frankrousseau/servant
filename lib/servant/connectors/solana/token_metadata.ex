defmodule Servant.Connectors.Solana.TokenMetadata do
  @moduledoc """
  Resolves SPL token mint addresses to name/symbol using the Jupiter strict token list.
  Results are cached in connector_environment with a 24h TTL.
  """

  alias Servant.Connectors

  @connector_type "solana"
  @namespace "token_metadata"
  @ttl_seconds 86_400
  @jupiter_url "https://token.jup.ag/strict"

  @doc """
  Resolves a list of mint addresses to `%{mint => %{symbol, name}}`.
  Fetches from cache first, bulk-fetches missing from Jupiter.
  """
  def resolve(mints) when is_list(mints) do
    mints = Enum.uniq(mints)

    # Check cache for each mint
    {cached, missing} =
      Enum.split_with(mints, fn mint ->
        case Connectors.get_env(@connector_type, @namespace, mint) do
          nil -> false
          _val -> true
        end
      end)

    cached_map =
      Map.new(cached, fn mint ->
        %{"data" => data} = Connectors.get_env(@connector_type, @namespace, mint)
        {mint, data}
      end)

    # Fetch missing from Jupiter
    fetched_map =
      if missing == [] do
        %{}
      else
        case fetch_jupiter_list() do
          {:ok, tokens} ->
            token_map = Map.new(tokens, fn t -> {t["address"], t} end)

            Map.new(missing, fn mint ->
              data =
                case Map.get(token_map, mint) do
                  nil ->
                    %{"symbol" => short_mint(mint), "name" => "Unknown token"}

                  token ->
                    %{"symbol" => token["symbol"], "name" => token["name"]}
                end

              # Cache the result
              expires_at =
                DateTime.utc_now()
                |> DateTime.add(@ttl_seconds, :second)
                |> DateTime.truncate(:second)

              Connectors.put_env(@connector_type, @namespace, mint, %{"data" => data}, expires_at)

              {mint, data}
            end)

          {:error, _reason} ->
            # On fetch failure, return fallback entries without caching
            Map.new(missing, fn mint ->
              {mint, %{"symbol" => short_mint(mint), "name" => "Unknown token"}}
            end)
        end
      end

    Map.merge(cached_map, fetched_map)
  end

  def resolve_one(mint) do
    result = resolve([mint])
    Map.get(result, mint, %{"symbol" => short_mint(mint), "name" => "Unknown token"})
  end

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
