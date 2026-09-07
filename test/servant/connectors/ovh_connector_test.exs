defmodule Servant.Connectors.OvhConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.OvhConnector

  @config %{
    "application_key" => "app-key",
    "application_secret" => "app-secret",
    "consumer_key" => "consumer-key"
  }

  describe "init/2" do
    test "requires the three OVH API keys" do
      assert OvhConnector.init(%{}, %{}) == {:error, :missing_application_key}

      assert OvhConnector.init(%{}, Map.delete(@config, "consumer_key")) ==
               {:error, :missing_consumer_key}

      assert OvhConnector.init(%{}, Map.put(@config, "application_secret", "  ")) ==
               {:error, :missing_application_secret}
    end

    test "defaults to the EU endpoint and trims pasted keys" do
      config = Map.put(@config, "application_key", " app-key\n")

      assert {:ok, state} = OvhConnector.init(%{}, config)
      assert state.app_key == "app-key"
      assert state.endpoint == "https://eu.api.ovh.com/1.0"
    end

    test "accepts a custom endpoint and drops its trailing slash" do
      config = Map.put(@config, "endpoint", "https://ca.api.ovh.com/1.0/")

      assert {:ok, state} = OvhConnector.init(%{}, config)
      assert state.endpoint == "https://ca.api.ovh.com/1.0"
    end

    test "an empty endpoint field falls back to the default" do
      assert {:ok, state} = OvhConnector.init(%{}, Map.put(@config, "endpoint", ""))
      assert state.endpoint == "https://eu.api.ovh.com/1.0"
    end
  end

  describe "signature/6" do
    test "signs the request the way OVH expects" do
      # Vector locked so a later reordering of the joined fields cannot pass.
      signature =
        OvhConnector.signature(
          "app-secret",
          "consumer-key",
          "GET",
          "https://eu.api.ovh.com/1.0/me/bill",
          "",
          1_366_560_945
        )

      assert signature == "$1$6aaf4d948daaecfb0f4d3dc31e3134584fccac1b"
    end
  end

  describe "build_entry/1" do
    test "maps a bill onto the invoice entry shape the scraper used" do
      bill = %{
        "billId" => "FR12345678",
        "date" => "2026-08-15T09:34:12+02:00",
        "priceWithTax" => %{
          "currencyCode" => "EUR",
          "text" => "10.99 €",
          "value" => 10.99
        },
        "pdfUrl" => "https://www.ovh.com/bill.pdf"
      }

      entry = OvhConnector.build_entry(bill)

      assert entry["kind"] == "invoice"
      assert entry["source"] == "ovh"
      assert entry["external_id"] == "ovh-FR12345678"
      assert entry["title"] == "OVH - 10.99 € (August 2026)"
      assert entry["occurred_at"] == ~U[2026-08-15 07:34:12Z]
      assert entry["data"]["amount"] == "10.99"
      assert entry["data"]["currency"] == "EUR"
      assert entry["data"]["url"] == "https://www.ovh.com/bill.pdf"
    end

    test "survives a bill with no price and a date-only date" do
      entry = OvhConnector.build_entry(%{"billId" => "FR1", "date" => "2026-07-01"})

      assert entry["external_id"] == "ovh-FR1"
      assert entry["title"] == "OVH - 0 EUR (July 2026)"
      assert entry["occurred_at"] == ~U[2026-07-01 00:00:00Z]
    end

    test "points at the stored PDF when there is one, keeping the remote link" do
      bill = %{"billId" => "FR1", "date" => "2026-07-01", "pdfUrl" => "https://ovh/bill.pdf"}
      entry = OvhConnector.build_entry(bill, "/files/u1/apps/files/abc.pdf")

      assert entry["data"]["url"] == "/files/u1/apps/files/abc.pdf"
      assert entry["data"]["remote_url"] == "https://ovh/bill.pdf"
    end
  end

  describe "new_ids/2" do
    test "drops bills already imported before any detail fetch" do
      known = MapSet.new(["ovh-FR1", "ovh-FR2"])

      assert OvhConnector.new_ids(["FR1", "FR2", "FR3"], known) == ["FR3"]
    end
  end

  describe "pdf_filename/1" do
    test "names the file from the date and the bill id" do
      bill = %{"billId" => "FR12345678", "date" => "2026-08-15T09:34:12+02:00"}

      assert OvhConnector.pdf_filename(bill) == "ovh-2026-08-15-FR12345678.pdf"
    end

    test "copes with a dateless bill" do
      assert OvhConnector.pdf_filename(%{"billId" => "FR1"}) == "ovh-FR1.pdf"
    end
  end

  describe "metadata" do
    test "identifies as an on-demand-capable daily invoice connector" do
      assert OvhConnector.id() == "ovh"
      assert OvhConnector.kind() == "invoice"
      assert OvhConnector.default_schedule() == "every_day"
      assert "on_demand" in OvhConnector.supported_schedules()
    end
  end
end
