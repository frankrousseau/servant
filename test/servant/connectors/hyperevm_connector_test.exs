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
end
