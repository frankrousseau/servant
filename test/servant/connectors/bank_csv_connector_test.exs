defmodule Servant.Connectors.BankCSVConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.BankCSVConnector

  describe "init/2" do
    test "succeeds with valid preset" do
      assert {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "n26"})
      assert state.preset == "n26"
      assert state.account_name == "Bank"
    end

    test "accepts custom account name" do
      assert {:ok, state} =
               BankCSVConnector.init(%{}, %{"preset" => "n26", "account_name" => "N26 Personal"})

      assert state.account_name == "N26 Personal"
    end

    test "defaults to generic preset" do
      assert {:ok, state} = BankCSVConnector.init(%{}, %{})
      assert state.preset == "generic"
    end

    test "fails with unknown preset" do
      assert {:error, _} = BankCSVConnector.init(%{}, %{"preset" => "unknown_bank"})
    end
  end

  describe "import_csv/2" do
    test "imports N26 CSV and builds entries" do
      {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "n26", "account_name" => "N26"})

      csv = """
      Date;Description;Amount;Currency;Balance
      05.02.2025;SUPERMARKET;-24,80;EUR;1230,50
      03.02.2025;SALARY;2500,00;EUR;1255,30
      """

      assert {:ok, entries} = BankCSVConnector.import_csv(csv, state)
      assert length(entries) == 2

      [payment, salary] = entries
      assert payment["kind"] == "bank_tx"
      assert payment["source"] == "bank_csv"
      assert String.contains?(payment["title"], "24.80")
      assert String.contains?(payment["title"], "SUPERMARKET")
      assert payment["data"]["direction"] == "sent"
      assert payment["data"]["account"] == "N26"

      assert salary["data"]["direction"] == "received"
      assert String.contains?(salary["title"], "2500.00")
    end

    test "generates deterministic external_ids for dedup" do
      {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "n26"})

      csv = "Date;Description;Amount;Currency;Balance\n05.02.2025;TEST;-10,00;EUR;100,00"

      {:ok, [entry1]} = BankCSVConnector.import_csv(csv, state)
      {:ok, [entry2]} = BankCSVConnector.import_csv(csv, state)

      assert entry1["external_id"] == entry2["external_id"]
    end
  end

  describe "metadata" do
    test "id is bank_csv" do
      assert BankCSVConnector.id() == "bank_csv"
    end

    test "only supports on_demand schedule" do
      assert BankCSVConnector.supported_schedules() == ["on_demand"]
    end

    test "sync returns empty list (import-only)" do
      {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "n26"})
      assert {:ok, [], ^state} = BankCSVConnector.sync(state)
    end
  end
end
