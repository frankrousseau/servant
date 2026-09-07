defmodule Servant.Connectors.EVMChainsTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.{ArbitrumConnector, BaseConnector, EthereumConnector}
  alias Servant.Connectors.HyperEVMConnector

  # Every chain is a thin configuration of Servant.Connectors.EVMConnector; the
  # behaviour is covered through HyperEVMConnector, this guards the wiring
  # (a wrong chain_id silently queries another chain on Etherscan V2).
  @chains [
    {EthereumConnector, "ethereum", 1, "ETH"},
    {ArbitrumConnector, "arbitrum", 42_161, "ETH"},
    {BaseConnector, "base", 8453, "ETH"},
    {HyperEVMConnector, "hyperevm", 999, "HYPE"}
  ]

  test "each chain declares its own id, chain_id and native symbol" do
    wallet = "0x1111111111111111111111111111111111111111"

    tx = %{
      "hash" => "0xaaa",
      "blockNumber" => "7",
      "timeStamp" => "1700000000",
      "isError" => "0",
      "from" => wallet,
      "to" => "0xdeadbeef00000000000000000000000000000001",
      "value" => "2000000000000000000"
    }

    for {connector, id, chain_id, symbol} <- @chains do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["chainid"] == to_string(chain_id)
        result = if conn.params["action"] == "txlist", do: [tx], else: []
        Req.Test.json(conn, %{"status" => "1", "result" => result})
      end)

      assert connector.id() == id
      assert connector.kind() == "blockchain_tx"

      {:ok, state} = connector.init(%{}, %{"wallet_address" => wallet})
      assert {:ok, [entry], _state} = connector.sync(state)
      assert entry["source"] == id
      assert entry["data"]["chain_id"] == chain_id
      assert [%{symbol: ^symbol}] = entry["data"]["transfers"]
      assert entry["title"] == "Sent 2 #{symbol} to 0xdead..0001"
    end
  end

  test "the chain ids are distinct" do
    ids = Enum.map(@chains, fn {_mod, id, _chain_id, _symbol} -> id end)
    chain_ids = Enum.map(@chains, fn {_mod, _id, chain_id, _symbol} -> chain_id end)
    assert Enum.uniq(ids) == ids
    assert Enum.uniq(chain_ids) == chain_ids
  end
end
