defmodule Servant.Connectors.Solana.TokenMetadataTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.Solana.TokenMetadata

  @usdc "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  @bonk "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"

  defp stub_jupiter(tokens) do
    Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, tokens) end)
  end

  test "resolves mints from the Jupiter list and caches them" do
    stub_jupiter([%{"address" => @usdc, "symbol" => "USDC", "name" => "USD Coin"}])

    assert TokenMetadata.resolve([@usdc]) == %{
             @usdc => %{"symbol" => "USDC", "name" => "USD Coin"}
           }

    assert %{"data" => %{"symbol" => "USDC"}} =
             Connectors.get_env("solana", "token_metadata", @usdc)
  end

  test "a cached mint is served without calling Jupiter" do
    Connectors.put_env("solana", "token_metadata", @usdc, %{
      "data" => %{"symbol" => "USDC", "name" => "USD Coin"}
    })

    Req.Test.stub(Servant.HTTP, fn _conn -> flunk("Jupiter should not be called") end)

    assert TokenMetadata.resolve([@usdc, @usdc]) == %{
             @usdc => %{"symbol" => "USDC", "name" => "USD Coin"}
           }
  end

  test "mixes cached and freshly fetched mints" do
    Connectors.put_env("solana", "token_metadata", @usdc, %{
      "data" => %{"symbol" => "USDC", "name" => "USD Coin"}
    })

    stub_jupiter([%{"address" => @bonk, "symbol" => "BONK", "name" => "Bonk"}])

    resolved = TokenMetadata.resolve([@usdc, @bonk])
    assert resolved[@usdc]["symbol"] == "USDC"
    assert resolved[@bonk]["symbol"] == "BONK"
  end

  test "a mint missing from the list becomes a shortened unknown, and is not cached" do
    stub_jupiter([])

    assert TokenMetadata.resolve([@bonk]) == %{
             @bonk => %{"symbol" => "DezX..B263", "name" => "Unknown token"}
           }

    refute Connectors.get_env("solana", "token_metadata", @bonk)
  end

  test "an expired cache entry is refetched" do
    yesterday = DateTime.add(DateTime.utc_now(), -1, :day)

    Connectors.put_env(
      "solana",
      "token_metadata",
      @usdc,
      %{"data" => %{"symbol" => "STALE", "name" => "Stale"}},
      yesterday
    )

    stub_jupiter([%{"address" => @usdc, "symbol" => "USDC", "name" => "USD Coin"}])

    assert TokenMetadata.resolve([@usdc])[@usdc]["symbol"] == "USDC"
  end

  test "a failed fetch falls back without caching" do
    Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

    assert TokenMetadata.resolve([@usdc])[@usdc]["name"] == "Unknown token"
    refute Connectors.get_env("solana", "token_metadata", @usdc)
  end

  test "resolve_one/1 returns a single mint" do
    stub_jupiter([%{"address" => @usdc, "symbol" => "USDC", "name" => "USD Coin"}])
    assert TokenMetadata.resolve_one(@usdc) == %{"symbol" => "USDC", "name" => "USD Coin"}
  end

  test "resolving nothing calls no API" do
    Req.Test.stub(Servant.HTTP, fn _conn -> flunk("Jupiter should not be called") end)
    assert TokenMetadata.resolve([]) == %{}
  end
end
