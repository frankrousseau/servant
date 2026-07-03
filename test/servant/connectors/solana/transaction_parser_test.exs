defmodule Servant.Connectors.Solana.TransactionParserTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.Solana.TransactionParser

  @wallet "WaLLeTAddr1111111111111111111111111111111111"
  @other "OtHeRAddr22222222222222222222222222222222222"

  defp base_tx(overrides \\ %{}) do
    tx = %{
      "slot" => 200_000_000,
      "blockTime" => 1_700_000_000,
      "transaction" => %{
        "signatures" => ["sig123abc"],
        "message" => %{
          "accountKeys" => [
            %{"pubkey" => @wallet},
            %{"pubkey" => @other},
            %{"pubkey" => "SysProgram1111111111111111111111111111111"}
          ]
        }
      },
      "meta" => %{
        "err" => nil,
        "preBalances" => [2_000_000_000, 5_000_000_000, 1],
        "postBalances" => [1_000_000_000, 6_000_000_000, 1],
        "preTokenBalances" => [],
        "postTokenBalances" => []
      }
    }

    Map.merge(tx, overrides)
  end

  describe "SOL transfers" do
    test "parses an outgoing SOL transfer" do
      tx = base_tx()
      assert {:ok, parsed} = TransactionParser.parse(tx, @wallet)

      assert parsed.signature == "sig123abc"
      assert parsed.slot == 200_000_000
      assert [transfer] = parsed.transfers
      assert transfer.type == "sol"
      assert transfer.direction == "sent"
      assert transfer.amount == 1_000_000_000
      assert transfer.symbol == "SOL"
      assert transfer.counterparty == @other
    end

    test "parses an incoming SOL transfer" do
      tx =
        base_tx(%{
          "meta" => %{
            "err" => nil,
            "preBalances" => [1_000_000_000, 6_000_000_000, 1],
            "postBalances" => [2_000_000_000, 5_000_000_000, 1],
            "preTokenBalances" => [],
            "postTokenBalances" => []
          }
        })

      assert {:ok, parsed} = TransactionParser.parse(tx, @wallet)
      assert [transfer] = parsed.transfers
      assert transfer.direction == "received"
      assert transfer.amount == 1_000_000_000
      # Regression: incoming transfers used to always resolve counterparty to nil
      # because the two-`if` block discarded the received-case result.
      assert transfer.counterparty == @other
    end
  end

  describe "SPL token transfers" do
    test "parses an incoming SPL transfer" do
      tx =
        base_tx(%{
          "meta" => %{
            "err" => nil,
            "preBalances" => [1_000_000_000, 1_000_000_000, 1],
            "postBalances" => [1_000_000_000, 1_000_000_000, 1],
            "preTokenBalances" => [
              %{
                "accountIndex" => 3,
                "mint" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                "owner" => @other,
                "uiTokenAmount" => %{"uiAmount" => 100.0, "decimals" => 6}
              }
            ],
            "postTokenBalances" => [
              %{
                "accountIndex" => 3,
                "mint" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                "owner" => @other,
                "uiTokenAmount" => %{"uiAmount" => 50.0, "decimals" => 6}
              },
              %{
                "accountIndex" => 4,
                "mint" => "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                "owner" => @wallet,
                "uiTokenAmount" => %{"uiAmount" => 50.0, "decimals" => 6}
              }
            ]
          }
        })

      assert {:ok, parsed} = TransactionParser.parse(tx, @wallet)
      spl = Enum.find(parsed.transfers, &(&1.type == "spl"))
      assert spl.direction == "received"
      assert spl.amount == 50.0
      assert spl.mint == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
      assert spl.counterparty == @other
    end
  end

  describe "skip conditions" do
    test "skips failed transactions" do
      tx = base_tx(%{"meta" => %{"err" => %{"InstructionError" => [0, "Custom"]}}})
      assert :skip = TransactionParser.parse(tx, @wallet)
    end

    test "skips transactions below threshold" do
      tx =
        base_tx(%{
          "meta" => %{
            "err" => nil,
            "preBalances" => [1_000_000_000, 5_000_000_000, 1],
            "postBalances" => [1_000_000_000 - 500, 5_000_000_000 + 500, 1],
            "preTokenBalances" => [],
            "postTokenBalances" => []
          }
        })

      # Default min_lamports is 1_000_000 — change of 500 is below
      assert :skip = TransactionParser.parse(tx, @wallet)
    end

    test "skips when wallet is not in the transaction" do
      tx = base_tx()
      assert :skip = TransactionParser.parse(tx, "SomeOtherWallet11111111111111111111111111111")
    end

    test "skips when no balance changes" do
      tx =
        base_tx(%{
          "meta" => %{
            "err" => nil,
            "preBalances" => [1_000_000_000, 5_000_000_000, 1],
            "postBalances" => [1_000_000_000, 5_000_000_000, 1],
            "preTokenBalances" => [],
            "postTokenBalances" => []
          }
        })

      assert :skip = TransactionParser.parse(tx, @wallet)
    end
  end
end
