defmodule Servant.Connectors.HyperEVMConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.HyperEVMConnector

  describe "init/2" do
    test "succeeds with valid wallet_address" do
      assert {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => "0xabc123"})
      assert state.wallet_address == "0xabc123"
      assert state.min_wei == 1_000_000_000_000_000
      assert state.last_block == 0
    end

    test "accepts custom explorer_url and min_wei" do
      config = %{
        "wallet_address" => "0xabc123",
        "explorer_url" => "https://custom-explorer.example.com/api",
        "min_wei" => 5_000_000_000_000_000_000
      }

      assert {:ok, state} = HyperEVMConnector.init(%{}, config)
      assert state.explorer_url == "https://custom-explorer.example.com/api"
      assert state.min_wei == 5_000_000_000_000_000_000
    end

    test "accepts last_block from config for resuming" do
      config = %{"wallet_address" => "0xabc", "last_block" => 500_000}
      assert {:ok, state} = HyperEVMConnector.init(%{}, config)
      assert state.last_block == 500_000
    end

    test "fails without wallet_address" do
      assert {:error, :missing_wallet_address} = HyperEVMConnector.init(%{}, %{})
    end

    test "accepts a .eth name, resolution deferred to sync" do
      assert {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => "frank.eth"})
      assert state.wallet_address == "frank.eth"
      assert state.resolved_address == nil
    end
  end

  describe "resolve_wallet/1" do
    test "plain address passes through without resolution" do
      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => "0xabc123"})
      assert {:ok, resolved} = HyperEVMConnector.resolve_wallet(state)
      assert resolved.resolved_address == "0xabc123"
    end

    test "already-resolved state is returned as-is (no HTTP call)" do
      state = %{wallet_address: "frank.eth", resolved_address: "0xabc123"}
      assert {:ok, ^state} = HyperEVMConnector.resolve_wallet(state)
    end
  end

  describe "metadata" do
    test "id is hyperevm" do
      assert HyperEVMConnector.id() == "hyperevm"
    end

    test "kind is transaction" do
      assert HyperEVMConnector.kind() == "blockchain_tx"
    end

    test "does not support continuous schedule" do
      refute "continuous" in HyperEVMConnector.supported_schedules()
    end

    test "supports expected schedules" do
      schedules = HyperEVMConnector.supported_schedules()
      assert "on_demand" in schedules
      assert "every_5_minutes" in schedules
      assert "every_hour" in schedules
      assert "every_day" in schedules
      assert "every_week" in schedules
    end

    test "default schedule is every_5_minutes" do
      assert HyperEVMConnector.default_schedule() == "every_5_minutes"
    end

    test "requires no credentials" do
      assert HyperEVMConnector.required_credentials() == []
    end
  end

  describe "sync/1" do
    @wallet "0x1111111111111111111111111111111111111111"
    @peer "0xdeadbeef00000000000000000000000000000001"

    defp native_tx(overrides \\ %{}) do
      Map.merge(
        %{
          "hash" => "0xaaa",
          "blockNumber" => "100",
          "timeStamp" => "1700000000",
          "isError" => "0",
          "from" => @wallet,
          "to" => @peer,
          "value" => "2000000000000000000"
        },
        overrides
      )
    end

    defp token_tx(overrides \\ %{}) do
      Map.merge(
        %{
          "hash" => "0xbbb",
          "blockNumber" => "101",
          "timeStamp" => "1700000100",
          "logIndex" => "3",
          "from" => @peer,
          "to" => @wallet,
          "value" => "1500000",
          "tokenDecimal" => "6",
          "tokenSymbol" => "USDC",
          "tokenName" => "USD Coin",
          "contractAddress" => "0xusdc"
        },
        overrides
      )
    end

    defp stub_explorer(txs, token_txs) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        result =
          case conn.params["action"] do
            "txlist" -> txs
            "tokentx" -> token_txs
          end

        Req.Test.json(conn, %{"status" => "1", "result" => result})
      end)
    end

    test "turns native and token transfers into entries and advances the cursor" do
      stub_explorer([native_tx()], [token_tx()])
      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => @wallet})

      assert {:ok, [native, token], new_state} = HyperEVMConnector.sync(state)

      assert native["kind"] == "blockchain_tx"
      assert native["source"] == "hyperevm"
      assert native["external_id"] == "0xaaa-native"
      assert native["title"] == "Sent 2 HYPE to 0xdead..0001"
      assert native["occurred_at"] == ~U[2023-11-14 22:13:20Z]
      assert native["data"]["chain_id"] == 999
      assert native["data"]["wallet"] == @wallet
      assert [%{symbol: "HYPE", direction: "sent"}] = native["data"]["transfers"]

      # ERC-20 rows share a hash, so the log index disambiguates them
      assert token["external_id"] == "0xbbb-erc20-3"
      assert token["title"] == "Received 1.5 USDC from 0xdead..0001"

      assert new_state.last_block == 101
      assert HyperEVMConnector.persisted_config(new_state) == %{"last_block" => 101}
    end

    test "resumes from the persisted block" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["startblock"] == "501"
        Req.Test.json(conn, %{"status" => "1", "result" => []})
      end)

      {:ok, state} =
        HyperEVMConnector.init(%{}, %{"wallet_address" => @wallet, "last_block" => 500})

      assert {:ok, [], %{last_block: 500}} = HyperEVMConnector.sync(state)
    end

    test "skips dust, failed and unrelated transactions" do
      stub_explorer(
        [
          native_tx(%{"value" => "1"}),
          native_tx(%{"isError" => "1", "hash" => "0xfail"}),
          native_tx(%{"from" => @peer, "to" => @peer, "hash" => "0xother"})
        ],
        []
      )

      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => @wallet})
      assert {:ok, [], _state} = HyperEVMConnector.sync(state)
    end

    test "resolves a .eth wallet once, then queries the resolved address" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/ens/resolve/frank.eth" do
          Req.Test.json(conn, %{"address" => @wallet})
        else
          assert conn.params["address"] == @wallet
          Req.Test.json(conn, %{"status" => "1", "result" => []})
        end
      end)

      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => "frank.eth"})
      assert {:ok, [], new_state} = HyperEVMConnector.sync(state)
      assert new_state.resolved_address == @wallet
    end

    test "an unresolvable .eth name fails the sync" do
      Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"address" => nil}) end)

      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => "nope.eth"})

      assert {:error, {:ens_resolution_failed, :ens_name_not_found}, ^state} =
               HyperEVMConnector.sync(state)
    end

    test "an explorer error fails the sync without moving the cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "0", "result" => "Missing/Invalid API Key"})
      end)

      {:ok, state} = HyperEVMConnector.init(%{}, %{"wallet_address" => @wallet})

      assert {:error, "Missing/Invalid API Key", errored} = HyperEVMConnector.sync(state)
      assert errored.last_block == 0
    end
  end
end
