defmodule Servant.Connectors.BankCSV.ParserTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.BankCSV.Parser

  describe "N26 format" do
    @n26_csv """
    Date;Description;Amount;Currency;Balance
    05.02.2025;SUPERMARKET PURCHASE;-24,80;EUR;1.230,50
    03.02.2025;SALARY PAYMENT;2.500,00;EUR;1.255,30
    01.02.2025;ATM WITHDRAWAL;-100,00;EUR;-1.244,70
    """

    test "parses N26 CSV correctly" do
      assert {:ok, txs} = Parser.parse(@n26_csv, "n26")
      assert length(txs) == 3
    end

    test "parses date in DD.MM.YYYY format" do
      {:ok, [tx | _]} = Parser.parse(@n26_csv, "n26")
      assert tx.date == ~D[2025-02-05]
    end

    test "parses negative amount as sent" do
      {:ok, [tx | _]} = Parser.parse(@n26_csv, "n26")
      assert tx.amount == -24.80
      assert tx.direction == "sent"
      assert tx.abs_amount == 24.80
    end

    test "parses positive amount as received" do
      {:ok, [_, tx | _]} = Parser.parse(@n26_csv, "n26")
      assert tx.amount == 2500.0
      assert tx.direction == "received"
    end

    test "handles European number format with thousands separator" do
      {:ok, [_, tx | _]} = Parser.parse(@n26_csv, "n26")
      assert tx.balance == 1255.30
    end

    test "preserves currency" do
      {:ok, [tx | _]} = Parser.parse(@n26_csv, "n26")
      assert tx.currency == "EUR"
    end

    test "parses ISO dates in N26 exports" do
      csv = """
      Date;Description;Amount;Currency;Balance
      2025-02-05;SUPERMARKET PURCHASE;-24,80;EUR;1.230,50
      """

      assert {:ok, [tx]} = Parser.parse(csv, "n26")
      assert tx.date == ~D[2025-02-05]
    end
  end

  describe "generic format" do
    @generic_csv """
    Date,Description,Amount,Currency,Balance
    2025-02-05,Coffee shop,-4.50,USD,1200.00
    2025-02-04,Freelance payment,500.00,USD,1204.50
    """

    test "parses generic CSV with ISO dates" do
      assert {:ok, txs} = Parser.parse(@generic_csv, "generic")
      assert length(txs) == 2
    end

    test "parses ISO date format" do
      {:ok, [tx | _]} = Parser.parse(@generic_csv, "generic")
      assert tx.date == ~D[2025-02-05]
    end

    test "parses dot decimal separator" do
      {:ok, [tx | _]} = Parser.parse(@generic_csv, "generic")
      assert tx.amount == -4.50
    end
  end

  describe "edge cases" do
    test "returns empty list for header-only CSV" do
      assert {:ok, []} = Parser.parse("Date;Description;Amount;Currency;Balance", "n26")
    end

    test "returns error for unknown preset" do
      assert {:error, "Unknown preset: nonexistent"} = Parser.parse("data", "nonexistent")
    end

    test "returns empty for empty CSV" do
      assert {:ok, []} = Parser.parse("", "n26")
    end

    test "skips lines with missing data" do
      csv = "Date;Description;Amount;Currency;Balance\n;;;"
      assert {:ok, []} = Parser.parse(csv, "n26")
    end
  end
end
