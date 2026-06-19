defmodule Servant.Connectors.BankCSVConnector do
  @moduledoc """
  Import connector for bank transaction CSV files.
  On-demand only — the user uploads a CSV file which gets parsed
  into transaction entries using a bank-specific preset.
  """

  use Servant.Connectors.Connector

  alias Servant.Connectors.BankCSV.Parser

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
    # This connector doesn't auto-sync — entries are created via import_csv/3
    {:ok, [], state}
  end

  @doc """
  Parses a CSV string and returns entry maps ready to be inserted.
  Called by the upload endpoint, not by the regular sync cycle.
  """
  def import_csv(csv_content, state) do
    case Parser.parse(csv_content, state.preset) do
      {:ok, transactions} ->
        entries =
          Enum.map(transactions, fn tx ->
            title =
              case tx.direction do
                "sent" ->
                  "Paid #{format_amount(tx.abs_amount)} #{tx.currency} — #{tx.description}"

                "received" ->
                  "Received #{format_amount(tx.abs_amount)} #{tx.currency} — #{tx.description}"
              end

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
              "data" => %{
                "description" => tx.description,
                "amount" => tx.amount,
                "abs_amount" => tx.abs_amount,
                "currency" => tx.currency,
                "direction" => tx.direction,
                "balance" => tx.balance,
                "account" => state.account_name
              },
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

  defp format_amount(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp format_amount(amount), do: to_string(amount)

  # Generate a deterministic ID from transaction data for dedup
  defp generate_external_id(tx) do
    data = "#{tx.date}|#{tx.description}|#{tx.amount}|#{tx.currency}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
end
