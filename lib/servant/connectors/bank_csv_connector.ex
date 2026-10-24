defmodule Servant.Connectors.BankCSVConnector do
  @moduledoc """
  Import connector for CSV files of bank transactions.
  On-demand only: the user uploads a CSV file. The connector parses the file
  into transaction entries with a bank-specific preset.
  """

  use Servant.Connectors.Connector

  import Ecto.Query
  alias Servant.Connectors.BankCSV.Parser
  alias Servant.Data.Entry
  alias Servant.Repo

  @impl true
  def id, do: "bank_csv"

  @impl true
  def name, do: "Bank Transactions (CSV)"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "bank_tx"

  @impl true
  def supported_schedules, do: ~w(on_demand)

  @impl true
  def default_schedule, do: "on_demand"

  @impl true
  def init(_credentials, config) do
    preset = Map.get(config, "preset", "generic")

    case Parser.get_preset(preset) do
      nil -> {:error, "Unknown bank preset: #{preset}"}
      _preset -> {:ok, %{preset: preset, account_name: Map.get(config, "account_name", "Bank")}}
    end
  end

  @impl true
  def sync(state) do
    # This connector does not sync automatically. import_csv/2 creates the entries.
    {:ok, [], state}
  end

  @doc """
  Parses a CSV string and returns entry maps that are ready for the insert.
  The upload endpoint calls this function, not the regular sync cycle.
  """
  def import_csv(csv_content, state) do
    case Parser.parse(csv_content, state.preset) do
      {:ok, transactions} ->
        entries =
          Enum.map(transactions, fn tx ->
            title = title(tx.direction, tx.abs_amount, tx.currency, tx.description)

            occurred_at =
              tx.date
              |> DateTime.new!(~T[12:00:00], "Etc/UTC")
              |> DateTime.truncate(:second)

            %{
              "kind" => "bank_tx",
              "source" => "bank_csv",
              "external_id" => generate_external_id(tx),
              "title" => title,
              "occurred_at" => occurred_at,
              "data" =>
                %{
                  "description" => tx.description,
                  "amount" => tx.amount,
                  "abs_amount" => tx.abs_amount,
                  "currency" => tx.currency,
                  "direction" => tx.direction,
                  "balance" => tx.balance,
                  "account" => state.account_name
                }
                |> Map.merge(original_data(tx)),
              "metadata" => %{
                "import_source" => state.preset
              }
            }
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Relabels the N26 transactions imported under their original currency.
  The amount of an N26 export is always the EUR debit, but the parser used
  to take the currency of a payment abroad ("USD") for the amount's, so the
  Finance app found no rate and left them out. The original currency is
  kept as `original_currency`; the original amount was never stored and
  takes a fresh account import to get. Returns `{updated, scanned}`.
  """
  def backfill_n26_currency(user_id \\ nil) do
    txs =
      from(entry in Entry,
        where: entry.kind == "bank_tx" and entry.source == "bank_csv",
        where: fragment("json_extract(?, '$.import_source')", entry.metadata) == "n26",
        where: fragment("upper(json_extract(?, '$.currency'))", entry.data) != "EUR"
      )
      |> then(fn query -> if user_id, do: where(query, user_id: ^user_id), else: query end)
      |> Repo.all()

    updated =
      Enum.count(txs, fn entry ->
        data =
          Map.merge(entry.data, %{
            "currency" => "EUR",
            "original_currency" => entry.data["currency"]
          })

        title = title(data["direction"], data["abs_amount"], "EUR", data["description"])

        match?(
          {:ok, _},
          entry |> Entry.changeset(%{title: title, data: data}) |> Repo.update()
        )
      end)

    {updated, length(txs)}
  end

  defp title("sent", amount, currency, description),
    do: "Paid #{format_amount(amount)} #{currency} - #{description}"

  defp title(_direction, amount, currency, description),
    do: "Received #{format_amount(amount)} #{currency} - #{description}"

  defp format_amount(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp format_amount(amount), do: to_string(amount)

  defp original_data(%{original_currency: currency} = tx) do
    %{
      "original_currency" => currency,
      "original_amount" => tx.original_amount,
      "exchange_rate" => tx.exchange_rate
    }
  end

  defp original_data(_tx), do: %{}

  # Generate a deterministic ID from the transaction data for the dedup. N26
  # payments abroad were once stored under their original currency: hashing
  # that one keeps a re-import of the same file from duplicating them.
  defp generate_external_id(tx) do
    currency = Map.get(tx, :original_currency) || tx.currency
    data = "#{tx.date}|#{tx.description}|#{tx.amount}|#{currency}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
end
