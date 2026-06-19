defmodule Servant.Connectors.InvoiceScraperConnector do
  @moduledoc """
  Generic invoice scraper connector.
  Uses Playwright (Node.js) provider scripts to login to various services
  and extract invoice data. Each provider is a JS recipe in priv/scrapers/providers/.
  """

  use Servant.Connectors.Connector

  require Logger

  @cmd_timeout 90_000

  @impl true
  def id, do: "invoice_scraper"

  @impl true
  def name, do: "Invoice Collector"

  @impl true
  def required_credentials, do: [:email, :password]

  @impl true
  def kind, do: "invoice"

  @impl true
  def supported_schedules, do: ~w(on_demand every_day every_week)

  @impl true
  def default_schedule, do: "on_demand"

  @impl true
  def init(_credentials, config) do
    provider = Map.get(config, "provider")
    email = Map.get(config, "email")
    password = Map.get(config, "password")

    cond do
      is_nil(provider) or provider == "" ->
        {:error, :missing_provider}

      is_nil(email) or email == "" ->
        {:error, :missing_email}

      is_nil(password) or password == "" ->
        {:error, :missing_password}

      true ->
        {:ok,
         %{
           provider: provider,
           email: email,
           password: password,
           totp_secret: Map.get(config, "totp_secret")
         }}
    end
  end

  @impl true
  def sync(state) do
    case run_scraper(state) do
      {:ok, invoices} ->
        entries = Enum.map(invoices, &build_entry(&1, state.provider))
        {:ok, entries, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp run_scraper(state) do
    script = script_path()

    unless File.exists?(script) do
      raise "Scraper not found at #{script}. Run 'npm install' in priv/scrapers/."
    end

    args =
      [
        script,
        "--provider",
        state.provider,
        "--email",
        state.email,
        "--password",
        state.password
      ] ++
        if state.totp_secret && state.totp_secret != "" do
          ["--totp-secret", state.totp_secret]
        else
          []
        end

    Logger.info("Running invoice scraper for provider: #{state.provider}")

    case System.cmd("node", args, stderr_to_stdout: false, timeout: @cmd_timeout) do
      {stdout, 0} ->
        parse_output(stdout)

      {_stdout, exit_code} ->
        {:error, "Scraper failed (exit code #{exit_code})"}
    end
  rescue
    e -> {:error, "Failed to run scraper: #{Exception.message(e)}"}
  end

  @doc false
  def parse_output(json_string) do
    case Jason.decode(String.trim(json_string)) do
      {:ok, %{"invoices" => invoices}} when is_list(invoices) ->
        {:ok, invoices}

      {:ok, _} ->
        {:error, "Unexpected JSON structure from scraper"}

      {:error, _} ->
        {:error, "Failed to parse scraper output"}
    end
  end

  @doc false
  def build_entry(invoice, provider) do
    date_str = invoice["date"] || ""
    amount = invoice["amount"] || "0"
    currency = invoice["currency"] || "USD"
    status = invoice["status"] || "paid"

    occurred_at = parse_date(date_str)

    month_label =
      case occurred_at do
        %DateTime{} = dt -> Calendar.strftime(dt, "%B %Y")
        _ -> date_str
      end

    provider_label = provider |> to_string() |> String.capitalize()
    title = "#{provider_label} — $#{amount} (#{month_label})"

    %{
      "kind" => "invoice",
      "source" => provider,
      "external_id" => invoice["id"] || "#{provider}-#{date_str}-#{amount}",
      "title" => title,
      "occurred_at" => occurred_at || DateTime.utc_now() |> DateTime.truncate(:second),
      "data" => %{
        "provider" => provider,
        "amount" => amount,
        "currency" => currency,
        "status" => status,
        "url" => invoice["url"]
      },
      "metadata" => %{}
    }
  end

  defp parse_date(str) do
    str = String.trim(str)

    cond do
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, str) ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end

      true ->
        parse_english_date(str)
    end
  end

  @months %{
    "january" => 1,
    "february" => 2,
    "march" => 3,
    "april" => 4,
    "may" => 5,
    "june" => 6,
    "july" => 7,
    "august" => 8,
    "september" => 9,
    "october" => 10,
    "november" => 11,
    "december" => 12,
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  defp parse_english_date(str) do
    case Regex.run(~r/(\w+)\s+(\d{1,2}),?\s+(\d{4})/, str) do
      [_, month_str, day_str, year_str] ->
        month = Map.get(@months, String.downcase(month_str))

        if month do
          case Date.new(String.to_integer(year_str), month, String.to_integer(day_str)) do
            {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
            _ -> nil
          end
        end

      _ ->
        nil
    end
  end

  defp script_path do
    case :code.priv_dir(:servant) do
      {:error, _} -> "priv/scrapers/invoice_scraper.js"
      dir -> Path.join(to_string(dir), "scrapers/invoice_scraper.js")
    end
  end
end
