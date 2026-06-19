defmodule Servant.Connectors.EVM.TransactionParserTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EVM.TransactionParser

  @wallet "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa"
  @other "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"

  defp native_tx(overrides \\ %{}) do
    tx = %{
      "hash" => "0xabc123",
      "blockNumber" => "1000000",
      "timeStamp" => "1700000000",
      "from" => @wallet,
      "to" => @other,
      "value" => "1000000000000000000",
      "isError" => "0",
      "gasUsed" => "21000",
      "gasPrice" => "1000000000"
    }

    Map.merge(tx, overrides)
  end

  defp token_tx(overrides \\ %{}) do
    tx = %{
      "hash" => "0xdef456",
      "blockNumber" => "1000001",
      "timeStamp" => "1700000060",
      "from" => @other,
      "to" => @wallet,
      "value" => "50000000",
      "contractAddress" => "0xCCcCcCCc00000000000000000000000000000001",
      "tokenName" => "USD Coin",
      "tokenSymbol" => "USDC",
      "tokenDecimal" => "6"
    }

    Map.merge(tx, overrides)
  end

  describe "parse_transaction/3 (native HYPE)" do
    test "parses an outgoing HYPE transfer" do
      tx = native_tx()
      assert {:ok, parsed} = TransactionParser.parse_transaction(tx, @wallet)

      assert parsed.tx_hash == "0xabc123"
      assert parsed.block_number == 1_000_000
      assert [transfer] = parsed.transfers
      assert transfer.type == "native"
      assert transfer.direction == "sent"
      assert transfer.amount == 1_000_000_000_000_000_000
      assert transfer.symbol == "HYPE"
      assert transfer.counterparty == @other
    end

    test "parses an incoming HYPE transfer" do
      tx = native_tx(%{"from" => @other, "to" => @wallet})
      assert {:ok, parsed} = TransactionParser.parse_transaction(tx, @wallet)

      assert [transfer] = parsed.transfers
      assert transfer.direction == "received"
      assert transfer.counterparty == @other
    end

    test "formats amount display correctly" do
      tx = native_tx(%{"value" => "1500000000000000000"})
      assert {:ok, parsed} = TransactionParser.parse_transaction(tx, @wallet)
      assert [transfer] = parsed.transfers
      assert transfer.amount_display == "1.5"
    end

    test "skips failed transactions" do
      tx = native_tx(%{"isError" => "1"})
      assert :skip = TransactionParser.parse_transaction(tx, @wallet)
    end

    test "skips zero-value transactions" do
      tx = native_tx(%{"value" => "0"})
      assert :skip = TransactionParser.parse_transaction(tx, @wallet)
    end

    test "skips transactions below threshold" do
      # 500 wei, well below default 1_000_000_000_000_000
      tx = native_tx(%{"value" => "500"})
      assert :skip = TransactionParser.parse_transaction(tx, @wallet)
    end

    test "skips self-transfers" do
      tx = native_tx(%{"from" => @wallet, "to" => @wallet})
      assert :skip = TransactionParser.parse_transaction(tx, @wallet)
    end

    test "handles case-insensitive address comparison" do
      tx = native_tx(%{"from" => String.downcase(@wallet), "to" => String.upcase(@other)})
      assert {:ok, parsed} = TransactionParser.parse_transaction(tx, @wallet)
      assert [transfer] = parsed.transfers
      assert transfer.direction == "sent"
    end
  end

  describe "parse_token_transfer/3 (ERC-20)" do
    test "parses an incoming token transfer" do
      tx = token_tx()
      assert {:ok, parsed} = TransactionParser.parse_token_transfer(tx, @wallet)

      assert parsed.tx_hash == "0xdef456"
      assert [transfer] = parsed.transfers
      assert transfer.type == "erc20"
      assert transfer.direction == "received"
      assert transfer.amount == 50_000_000
      assert transfer.symbol == "USDC"
      assert transfer.token_address == "0xCCcCcCCc00000000000000000000000000000001"
      assert transfer.counterparty == @other
    end

    test "parses an outgoing token transfer" do
      tx = token_tx(%{"from" => @wallet, "to" => @other})
      assert {:ok, parsed} = TransactionParser.parse_token_transfer(tx, @wallet)

      assert [transfer] = parsed.transfers
      assert transfer.direction == "sent"
      assert transfer.counterparty == @other
    end

    test "formats token amount display with correct decimals" do
      tx = token_tx(%{"value" => "1500000", "tokenDecimal" => "6"})
      assert {:ok, parsed} = TransactionParser.parse_token_transfer(tx, @wallet)
      assert [transfer] = parsed.transfers
      assert transfer.amount_display == "1.5"
    end

    test "skips self-transfers" do
      tx = token_tx(%{"from" => @wallet, "to" => @wallet})
      assert :skip = TransactionParser.parse_token_transfer(tx, @wallet)
    end
  end
end
