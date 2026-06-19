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
