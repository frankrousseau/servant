defmodule Servant.Connectors.SolanaConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.SolanaConnector

  describe "init/2" do
    test "succeeds with valid wallet_address" do
      assert {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "abc123"})
      assert state.wallet_address == "abc123"
      assert state.min_lamports == 1_000_000
      assert state.last_signature == nil
    end

    test "accepts custom rpc_url and min_sol_amount" do
      config = %{
        "wallet_address" => "abc123",
        "rpc_url" => "https://my-rpc.example.com",
        "min_sol_amount" => 5_000_000
      }

      assert {:ok, state} = SolanaConnector.init(%{}, config)
      assert state.rpc_url == "https://my-rpc.example.com"
      assert state.min_lamports == 5_000_000
    end

    test "fails without wallet_address" do
      assert {:error, :missing_wallet_address} = SolanaConnector.init(%{}, %{})
    end

    test "accepts a .sol domain, resolution deferred to sync" do
      assert {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "frank.sol"})
      assert state.wallet_address == "frank.sol"
      assert state.resolved_address == nil
    end
  end

  describe "resolve_wallet/1" do
    test "plain address passes through without resolution" do
      {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "abc123"})
      assert {:ok, resolved} = SolanaConnector.resolve_wallet(state)
      assert resolved.resolved_address == "abc123"
    end

    test "already-resolved state is returned as-is (no HTTP call)" do
      state = %{wallet_address: "frank.sol", resolved_address: "abc123"}
      assert {:ok, ^state} = SolanaConnector.resolve_wallet(state)
    end
  end

  describe "metadata" do
    test "id is solana" do
      assert SolanaConnector.id() == "solana"
    end

    test "kind is transaction" do
      assert SolanaConnector.kind() == "blockchain_tx"
    end

    test "does not support continuous schedule" do
      refute "continuous" in SolanaConnector.supported_schedules()
    end

    test "supports expected schedules" do
      schedules = SolanaConnector.supported_schedules()
      assert "on_demand" in schedules
      assert "every_5_minutes" in schedules
      assert "every_hour" in schedules
      assert "every_day" in schedules
      assert "every_week" in schedules
    end

    test "default schedule is every_5_minutes" do
      assert SolanaConnector.default_schedule() == "every_5_minutes"
    end
  end
end
