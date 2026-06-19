defmodule Servant.Connectors.InvoiceScraperConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.InvoiceScraperConnector

  describe "init/2" do
    test "succeeds with provider, email and password" do
      config = %{"provider" => "anthropic", "email" => "a@b.com", "password" => "secret"}
      assert {:ok, state} = InvoiceScraperConnector.init(%{}, config)
      assert state.provider == "anthropic"
      assert state.email == "a@b.com"
      assert state.totp_secret == nil
    end

    test "accepts optional totp_secret" do
      config = %{"provider" => "anthropic", "email" => "a@b.com", "password" => "s", "totp_secret" => "JBSWY3DPEHPK3PXP"}
      assert {:ok, state} = InvoiceScraperConnector.init(%{}, config)
      assert state.totp_secret == "JBSWY3DPEHPK3PXP"
    end

    test "fails without provider" do
      assert {:error, :missing_provider} = InvoiceScraperConnector.init(%{}, %{"email" => "a", "password" => "b"})
    end

    test "fails without email" do
      assert {:error, :missing_email} = InvoiceScraperConnector.init(%{}, %{"provider" => "x", "password" => "b"})
    end

    test "fails without password" do
      assert {:error, :missing_password} = InvoiceScraperConnector.init(%{}, %{"provider" => "x", "email" => "a"})
    end
  end

  describe "parse_output/1" do
    test "parses valid JSON with invoices" do
      json = ~s({"invoices": [{"id": "inv-1", "date": "2025-03-01", "amount": "142.50", "currency": "USD", "status": "paid"}]})
      assert {:ok, [inv]} = InvoiceScraperConnector.parse_output(json)
      assert inv["id"] == "inv-1"
      assert inv["amount"] == "142.50"
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = InvoiceScraperConnector.parse_output("not json")
    end

    test "returns error for unexpected structure" do
      assert {:error, _} = InvoiceScraperConnector.parse_output(~s({"data": []}))
    end
  end

  describe "build_entry/2" do
    test "builds entry from invoice with ISO date" do
      invoice = %{"id" => "inv-1", "date" => "2025-03-01", "amount" => "142.50", "currency" => "USD", "status" => "paid"}
      entry = InvoiceScraperConnector.build_entry(invoice, "anthropic")

      assert entry["kind"] == "invoice"
      assert entry["source"] == "anthropic"
      assert entry["external_id"] == "inv-1"
      assert String.contains?(entry["title"], "Anthropic")
      assert String.contains?(entry["title"], "142.50")
      assert String.contains?(entry["title"], "March 2025")
      assert entry["data"]["provider"] == "anthropic"
    end

    test "builds entry from invoice with English date" do
      invoice = %{"date" => "March 1, 2025", "amount" => "50.00"}
      entry = InvoiceScraperConnector.build_entry(invoice, "ovh")

      assert String.contains?(entry["title"], "Ovh")
      assert entry["occurred_at"] == ~U[2025-03-01 00:00:00Z]
    end

    test "uses provider as source" do
      invoice = %{"date" => "2025-01-15", "amount" => "10"}
      entry = InvoiceScraperConnector.build_entry(invoice, "notion")
      assert entry["source"] == "notion"
    end
  end

  describe "metadata" do
    test "id is invoice_scraper" do
      assert InvoiceScraperConnector.id() == "invoice_scraper"
    end

    test "kind is invoice" do
      assert InvoiceScraperConnector.kind() == "invoice"
    end

    test "supports on_demand, every_day, every_week" do
      schedules = InvoiceScraperConnector.supported_schedules()
      assert "on_demand" in schedules
      assert "every_day" in schedules
      assert "every_week" in schedules
      refute "every_5_minutes" in schedules
    end
  end
end
