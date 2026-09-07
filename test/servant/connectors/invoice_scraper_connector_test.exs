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
      config = %{
        "provider" => "anthropic",
        "email" => "a@b.com",
        "password" => "s",
        "totp_secret" => "JBSWY3DPEHPK3PXP"
      }

      assert {:ok, state} = InvoiceScraperConnector.init(%{}, config)
      assert state.totp_secret == "JBSWY3DPEHPK3PXP"
    end

    test "fails without provider" do
      assert {:error, :missing_provider} =
               InvoiceScraperConnector.init(%{}, %{"email" => "a", "password" => "b"})
    end

    test "fails without email" do
      assert {:error, :missing_email} =
               InvoiceScraperConnector.init(%{}, %{"provider" => "x", "password" => "b"})
    end

    test "fails without password" do
      assert {:error, :missing_password} =
               InvoiceScraperConnector.init(%{}, %{"provider" => "x", "email" => "a"})
    end
  end

  describe "parse_output/1" do
    test "parses valid JSON with invoices" do
      json =
        ~s({"invoices": [{"id": "inv-1", "date": "2025-03-01", "amount": "142.50", "currency": "USD", "status": "paid"}]})

      assert {:ok, [inv]} = InvoiceScraperConnector.parse_output(json)
      assert inv["id"] == "inv-1"
      assert inv["amount"] == "142.50"
    end

    # stderr is folded into stdout so the diagnostics survive; the payload is
    # still the last thing the script writes.
    test "reads the payload under the scraper's log lines" do
      output = """
      [scraper] Starting scraper for provider: OVH
      [scraper] Logging in...
      [ovh] Session API returned 2 bills
      {"invoices": [{"id": "ovh-1", "date": "2026-03-01", "amount": "12.00"}]}\
      """

      assert {:ok, [inv]} = InvoiceScraperConnector.parse_output(output)
      assert inv["id"] == "ovh-1"
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = InvoiceScraperConnector.parse_output("not json")
    end

    test "returns error for unexpected structure" do
      assert {:error, _} = InvoiceScraperConnector.parse_output(~s({"data": []}))
    end
  end

  describe "diagnostic/1" do
    # Verbatim from a run whose browser was missing: the actionable sentence
    # sits on the ERROR line, above six lines of Playwright's banner.
    test "picks the error line out of a real failing run" do
      output = """
      [scraper] Starting scraper for provider: OVH
      [scraper] ERROR: browserType.launch: Executable doesn't exist at /opt/playwright/chromium_headless_shell-1208/chrome-headless-shell
      ╔════════════════════════════════════════╗
      ║ Please run the following command:      ║
      ║     npx playwright install             ║
      ╚════════════════════════════════════════╝
      """

      message = InvoiceScraperConnector.diagnostic(output)
      assert message =~ "browserType.launch"
      assert message =~ "Executable doesn't exist"
    end

    test "keeps the last error when several are logged" do
      output = "[scraper] ERROR: first\n[ovh] ERROR: 2FA required but no totp_secret provided\n"
      assert InvoiceScraperConnector.diagnostic(output) =~ "2FA required"
    end

    test "falls back to the tail when nothing is flagged as an error" do
      output = "[scraper] Logging in...\n[ovh] Session API failed (GET /me/bill -> 403)\n"
      message = InvoiceScraperConnector.diagnostic(output)
      assert message =~ "403"
    end

    test "says so when the scraper printed nothing" do
      assert InvoiceScraperConnector.diagnostic("  \n\n") == "no output from the scraper"
    end

    test "caps a runaway log" do
      assert String.length(InvoiceScraperConnector.diagnostic(String.duplicate("x", 5_000))) ==
               300
    end
  end

  describe "build_entry/2" do
    test "builds entry from invoice with ISO date" do
      invoice = %{
        "id" => "inv-1",
        "date" => "2025-03-01",
        "amount" => "142.50",
        "currency" => "USD",
        "status" => "paid"
      }

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

  # The provider name is interpolated into `providers/<name>.js` by the Node
  # script, so anything but a bare identifier could execute arbitrary JS.
  describe "provider validation" do
    defp init_with(provider) do
      InvoiceScraperConnector.init(%{}, %{
        "provider" => provider,
        "email" => "a@b.c",
        "password" => "pw"
      })
    end

    test "accepts bare lowercase identifiers" do
      assert {:ok, %{provider: "anthropic"}} = init_with("anthropic")
      assert {:ok, %{provider: "banque_postale2"}} = init_with("banque_postale2")
    end

    test "refuses anything that could escape the providers directory" do
      for provider <- [
            "../../../etc/passwd",
            "../evil",
            "sub/dir",
            "anthropic.js",
            "Anthropic",
            "anthropic ",
            "anthropic;rm -rf /",
            "anthropic-2"
          ] do
        assert init_with(provider) == {:error, :invalid_provider},
               "#{inspect(provider)} should not be accepted as a provider"
      end
    end

    test "refuses a provider that is not a string" do
      assert {:error, :missing_provider} = init_with(nil)
      assert {:error, :missing_provider} = init_with("")
      assert {:error, :invalid_provider} = init_with(42)
    end
  end

  describe "amount and date formatting" do
    defp title_for(invoice), do: InvoiceScraperConnector.build_entry(invoice, "x")["title"]

    test "prefixes the known currency symbols and suffixes the rest" do
      assert title_for(%{"amount" => "10", "currency" => "USD"}) =~ "$10"
      assert title_for(%{"amount" => "10", "currency" => "EUR"}) =~ "€10"
      assert title_for(%{"amount" => "10", "currency" => "GBP"}) =~ "£10"
      assert title_for(%{"amount" => "10", "currency" => "chf"}) =~ "10 CHF"
    end

    test "defaults to USD and a zero amount" do
      assert title_for(%{}) =~ "$0"
    end

    test "an unparsable date still yields an entry" do
      entry = InvoiceScraperConnector.build_entry(%{"date" => "sometime last year"}, "x")

      assert %DateTime{} = entry["occurred_at"]
      assert entry["kind"] == "invoice"
    end

    test "an invoice without an id gets a deterministic external id" do
      invoice = %{"date" => "2025-03-01", "amount" => "10"}

      assert InvoiceScraperConnector.build_entry(invoice, "x")["external_id"] ==
               InvoiceScraperConnector.build_entry(invoice, "x")["external_id"]
    end
  end
end
