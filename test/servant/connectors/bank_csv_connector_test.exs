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

    test "imports a Banque Postale export, skipping the metadata preamble" do
      {:ok, state} =
        BankCSVConnector.init(%{}, %{"preset" => "banque_postale", "account_name" => "CCP"})

      csv = """
      Numéro Compte ;1234567890
      Type ;Compte Courant Postal
      Compte tenu en ;euros
      Date ;12/07/2026
      Solde (EUROS) ;+1234,56
      ;
      Date;Libellé;Montant(EUROS)
      10/07/2026;"PRELEVEMENT DE EDF";-45,67
      09/07/2026;"VIREMENT DE CPAM";+123,45
      """

      assert {:ok, [edf, cpam]} = BankCSVConnector.import_csv(csv, state)

      assert edf["data"]["direction"] == "sent"
      assert edf["data"]["amount"] == -45.67
      assert edf["data"]["currency"] == "EUR"
      assert edf["data"]["account"] == "CCP"
      assert edf["occurred_at"].day == 10

      assert cpam["data"]["direction"] == "received"
      assert cpam["data"]["amount"] == 123.45
    end

    test "imports a CIC export with split debit/credit columns" do
      {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "cic", "account_name" => "CIC"})

      csv = """
      Date;Date de valeur;Débit;Crédit;Libellé;Solde
      09/07/2026;09/07/2026;-45,67;;PRLV EDF;1234,56
      08/07/2026;08/07/2026;;2500,00;VIR SALAIRE;1280,23
      """

      assert {:ok, [edf, salary]} = BankCSVConnector.import_csv(csv, state)

      assert edf["data"]["amount"] == -45.67
      assert edf["data"]["balance"] == 1234.56
      assert salary["data"]["amount"] == 2500.0
      assert salary["data"]["direction"] == "received"
    end

    test "decodes Latin-1 exports and reports a missing header" do
      {:ok, state} = BankCSVConnector.init(%{}, %{"preset" => "banque_postale"})

      # "Libellé" and a latin-1 label, encoded as ISO-8859-1 bytes
      csv =
        :unicode.characters_to_binary(
          "Date;Libellé;Montant(EUROS)\n10/07/2026;ACHAT CB BOULANGERIE HÉLÈNE;-3,50\n",
          :utf8,
          :latin1
        )

      assert {:ok, [entry]} = BankCSVConnector.import_csv(csv, state)
      assert entry["data"]["description"] == "ACHAT CB BOULANGERIE HÉLÈNE"

      assert {:error, message} = BankCSVConnector.import_csv("foo;bar\n1;2\n", state)
      assert message =~ "header"
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
