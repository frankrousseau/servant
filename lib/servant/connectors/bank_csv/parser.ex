defmodule Servant.Connectors.BankCSV.Parser do
  @moduledoc """
  Parses bank transaction CSV files using configurable presets.
  Each preset defines the CSV structure for a specific bank.
  """

  @presets %{
    "n26" => %{
      delimiter: ";",
      date_column: "Date",
      description_column: "Description",
      amount_column: "Amount",
      currency_column: "Currency",
      balance_column: "Balance",
      date_format: :eu_dot,
      decimal_separator: ","
    },
    "revolut" => %{
      delimiter: ",",
      date_column: "Started Date",
      description_column: "Description",
      amount_column: "Amount",
      currency_column: "Currency",
      balance_column: "Balance",
      date_format: :iso,
      decimal_separator: "."
    },
    "generic" => %{
      delimiter: ",",
      date_column: "Date",
      description_column: "Description",
      amount_column: "Amount",
      currency_column: "Currency",
      balance_column: "Balance",
      date_format: :iso,
      decimal_separator: "."
    }
  }

  def available_presets, do: Map.keys(@presets)

  def get_preset(name), do: Map.get(@presets, name)

  @doc """
  Parses a CSV string into a list of transaction maps.
  Returns `{:ok, transactions}` or `{:error, reason}`.
  """
  def parse(csv_content, preset_name) when is_binary(csv_content) do
    case Map.get(@presets, preset_name) do
      nil ->
        {:error, "Unknown preset: #{preset_name}"}

      preset ->
        do_parse(csv_content, preset)
    end
  end

  defp do_parse(csv_content, preset) do
    lines =
      csv_content
      |> strip_bom()
      |> String.trim()
      |> String.split(~r/\r?\n/)

    case lines do
      [] ->
        {:error, "Empty CSV"}

      [_header_line] ->
        {:ok, []}

      [header_line | data_lines] ->
        headers = split_line(header_line, preset.delimiter)

        transactions =
          data_lines
          |> Enum.with_index(2)
          |> Enum.flat_map(fn {line, line_num} ->
            case parse_line(line, headers, preset, line_num) do
              {:ok, tx} -> [tx]
              :skip -> []
            end
          end)

        {:ok, transactions}
    end
  end

  defp parse_line(line, headers, preset, _line_num) do
    values = split_line(line, preset.delimiter)

    if length(values) < length(headers) do
      :skip
    else
      row = Enum.zip(headers, values) |> Map.new()

      raw_date = Map.get(row, preset.date_column, "")

      date =
        parse_date(raw_date, preset.date_format) ||
          parse_date(raw_date, :iso)
      description = Map.get(row, preset.description_column, "") |> String.trim()
      amount = parse_amount(Map.get(row, preset.amount_column, ""), preset.decimal_separator)
      currency = Map.get(row, preset[:currency_column] || "Currency", "") |> String.trim()

      balance =
        parse_amount(
          Map.get(row, preset[:balance_column] || "Balance", ""),
          preset.decimal_separator
        )

      if date == nil or amount == nil or description == "" do
        :skip
      else
        direction = if amount < 0, do: "sent", else: "received"

        {:ok,
         %{
           date: date,
           description: description,
           amount: amount,
           abs_amount: abs(amount),
           currency: if(currency != "", do: currency, else: "EUR"),
           balance: balance,
           direction: direction
         }}
      end
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp split_line(line, delimiter) do
    # Simple CSV split handling quoted fields
    line
    |> String.split(delimiter)
    |> Enum.map(fn field ->
      field
      |> String.trim()
      |> String.trim("\"")
    end)
  end

  # DD.MM.YYYY
  defp parse_date(str, :eu_dot) do
    case Regex.run(~r/^(\d{2})\.(\d{2})\.(\d{4})$/, str) do
      [_, day, month, year] ->
        case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # YYYY-MM-DD or YYYY-MM-DD HH:MM:SS
  defp parse_date(str, :iso) do
    str = str |> String.trim() |> String.slice(0, 10)

    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_, _), do: nil

  defp parse_amount(str, decimal_separator) do
    str =
      str
      |> String.trim()
      |> String.replace(" ", "")

    str =
      case decimal_separator do
        "," ->
          # "1.230,50" -> "1230.50"
          str |> String.replace(".", "") |> String.replace(",", ".")

        _ ->
          # "1,230.50" -> "1230.50"
          str |> String.replace(",", "")
      end

    case Float.parse(str) do
      {val, _} -> val
      :error -> nil
    end
  end
end
