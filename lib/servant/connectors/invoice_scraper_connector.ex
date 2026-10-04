defmodule Servant.Connectors.InvoiceScraperConnector do
  @moduledoc """
  Generic connector that scrapes invoices.
  Uses provider scripts for Playwright (Node.js) to log in to different services
  and extract the invoice data. Each provider is a JS recipe in priv/scrapers/providers/.
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
    provider = config_value(config, "provider")
    email = config_value(config, "email")
    password = config_value(config, "password")

    cond do
      is_nil(provider) or provider == "" ->
        {:error, :missing_provider}

      not valid_provider?(provider) ->
        {:error, :invalid_provider}

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
           totp_secret: config_value(config, "totp_secret")
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

  # The Node script interpolates the provider name into a filesystem path
  # (`providers/<name>.js`). Restrict the name to a bare identifier, with no
  # path separators and no `..`. This prevents traversal into arbitrary JS and
  # the execution of that JS. The guard in priv/scrapers/invoice_scraper.js is
  # the same.
  defp valid_provider?(provider) when is_binary(provider),
    do: Regex.match?(~r/^[a-z0-9_]+$/, provider)

  defp valid_provider?(_), do: false

  defp run_scraper(state) do
    do_run_scraper(state)
  rescue
    e -> {:error, "Failed to run scraper: #{Exception.message(e)}"}
  end

  # Make sure that the runtime requirements are present before the run. Then a
  # missing piece gives an error that the user can act on, not a raw :enoent.
  # The default Docker image does not include Node.js (see docs/deploy.md).
  defp do_run_scraper(state) do
    script = script_path()
    node = System.find_executable("node")

    cond do
      is_nil(node) ->
        {:error,
         "Node.js is not installed on the server. The Invoice Collector runs " <>
           "Playwright scripts via node; see 'Invoice Collector' in docs/deploy.md."}

      not File.exists?(script) ->
        {:error, "Scraper script not found at #{script}."}

      not File.dir?(Path.join(Path.dirname(script), "node_modules")) ->
        {:error,
         "Scraper dependencies are missing: run 'npm install' in #{Path.dirname(script)}."}

      true ->
        run_node(node, script, state)
    end
  end

  defp run_node(node, script, state) do
    # Only the provider (not a secret) goes on the command line. Pass the secrets
    # through environment variables, so they do not leak through `ps`/`/proc`.
    args = [script, "--provider", state.provider]

    env =
      [
        {"SCRAPER_EMAIL", state.email},
        {"SCRAPER_PASSWORD", state.password}
      ] ++
        if state.totp_secret && state.totp_secret != "" do
          [{"SCRAPER_TOTP_SECRET", state.totp_secret}]
        else
          []
        end

    Logger.info("Running invoice scraper for provider: #{state.provider}")

    # `System.cmd/3` has no `:timeout` option (it silently ignored the option).
    # As a result, a hung Playwright script blocks this worker forever. Run the
    # script in a Task and apply the timeout with Task.yield/2 + Task.shutdown/2.
    #
    # stderr goes into stdout. The script writes every diagnostic to stderr,
    # and that includes the one line that says what broke. When that output
    # went to the stderr of the OS, it was out of reach of the UI and of the
    # audit log. The JSON payload is the last write of the script and contains
    # no newline. As a result, `parse_output/1` still finds it under the log
    # lines.
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(node, args, stderr_to_stdout: true, env: env)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, @cmd_timeout) || Task.shutdown(task) do
      {:ok, {:ok, {output, 0}}} ->
        parse_output(output)

      {:ok, {:ok, {output, exit_code}}} ->
        Logger.error("Invoice scraper output [#{state.provider}]:\n#{output}")
        {:error, "Scraper failed (exit #{exit_code}): #{diagnostic(output)}"}

      {:ok, {:error, message}} ->
        {:error, "Failed to run scraper: #{message}"}

      # Task.yield/2 returns {:exit, reason} if the task died abnormally. Without
      # this clause, that result raises a CaseClauseError and crashes the worker.
      {:exit, reason} ->
        {:error, "Scraper crashed: #{inspect(reason)}"}

      nil ->
        {:error, "Scraper timed out after #{@cmd_timeout}ms"}
    end
  end

  # The payload is the last write of the script. All the text above it is log lines.
  @doc false
  def parse_output(output) do
    case Jason.decode(last_line(output)) do
      {:ok, %{"invoices" => invoices}} when is_list(invoices) ->
        {:ok, invoices}

      {:ok, _} ->
        {:error, "Unexpected JSON structure from scraper"}

      {:error, _} ->
        {:error, "Scraper produced no invoices: #{diagnostic(output)}"}
    end
  end

  # This is the text to show to the user after a failed run. It is the line
  # that the script flagged as the error. If the script died and flagged no
  # line, it is the tail of the log of the script.
  @max_diagnostic 300

  @doc false
  def diagnostic(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    message =
      case Enum.filter(lines, &String.contains?(&1, "ERROR:")) do
        [] -> Enum.join(Enum.take(lines, -3), " | ")
        errors -> List.last(errors)
      end

    case String.trim(message) do
      "" -> "no output from the scraper"
      text -> String.slice(text, 0, @max_diagnostic)
    end
  end

  defp last_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> Kernel.||("")
    |> String.trim()
  end

  # Put the symbol before the amount for the common currencies. For the other
  # currencies, put the code after the amount (for example "12.00 CHF"). Never
  # hard-code "$".
  defp format_amount(amount, currency) do
    case String.upcase(to_string(currency)) do
      "USD" -> "$#{amount}"
      "EUR" -> "€#{amount}"
      "GBP" -> "£#{amount}"
      other -> "#{amount} #{other}"
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
    title = "#{provider_label} - #{format_amount(amount, currency)} (#{month_label})"

    %{
      "kind" => "invoice",
      "source" => provider,
      "external_id" => invoice["id"] || "#{provider}-#{date_str}-#{amount}",
      "title" => title,
      "occurred_at" => occurred_at || DateTime.truncate(DateTime.utc_now(), :second),
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
