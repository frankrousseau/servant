defmodule Servant.Connectors.EVM.ExplorerTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EVM.Explorer

  describe "parse_body/1" do
    test "status 1 with a result list returns the transactions" do
      tx = %{"hash" => "0xabc", "blockNumber" => "123"}
      assert Explorer.parse_body(%{"status" => "1", "result" => [tx]}) == {:ok, [tx]}
    end

    test "status 0 with an empty result list is just no transactions" do
      body = %{"status" => "0", "message" => "No transactions found", "result" => []}
      assert Explorer.parse_body(body) == {:ok, []}
    end

    # Etherscan reports API errors as HTTP 200 + status "0" with the error in
    # result; these must surface as sync failures, not empty syncs (the V1
    # sunset went unnoticed for weeks because they were swallowed).
    test "status 0 with an error message in result is an error" do
      deprecated =
        "You are using a deprecated V1 endpoint, switch to Etherscan API V2 " <>
          "using https://docs.etherscan.io/v2-migration"

      body = %{"status" => "0", "message" => "NOTOK", "result" => deprecated}
      assert Explorer.parse_body(body) == {:error, deprecated}

      body = %{"status" => "0", "message" => "NOTOK", "result" => "Missing/Invalid API Key"}
      assert Explorer.parse_body(body) == {:error, "Missing/Invalid API Key"}
    end

    test "an unrecognized body shape is an error" do
      assert {:error, _} = Explorer.parse_body(%{"unexpected" => true})
    end
  end
end
