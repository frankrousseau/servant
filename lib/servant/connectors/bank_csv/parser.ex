defmodule Servant.Connectors.BankCSV.Parser do
  @moduledoc """
  Parses bank transaction CSV files using configurable presets.
  Each preset defines the CSV structure for a specific bank.
  """

  @n26_classic %{
    delimiter: ";",
    date_column: "Date",
    description_column: "Description",
    amount_column: "Amount",
    currency_column: "Currency",
    balance_column: "Balance",
    date_format: :eu_dot,
    decimal_separator: ","
  }

  @n26_modern %{
    delimiter: ",",
    date_column: "Booking Date",
    description_columns: ["Partner Name", "Payment Reference", "Type"],
    amount_column: "Amount (EUR)",
    currency_column: "Original Currency",
    balance_column: nil,
    date_format: :iso,
    decimal_separator: "."
  }

  @presets %{
    "n26" => :detect,
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

  def get_preset("n26"), do: @n26_classic
  def get_preset(name), do: Map.get(@presets, name)

  @doc """
  Parses a CSV string into a list of transaction maps.
  Returns `{:ok, transactions}` or `{:error, reason}`.
  """
  def parse(csv_content, preset_name) when is_binary(csv_content) do
    case Map.get(@presets, preset_name) do
      nil ->
        {:error, "Unknown preset: #{preset_name}"}

      :detect ->
        do_parse(csv_content, detect_n26_preset(csv_content))

      preset ->
        do_parse(csv_content, preset)
    end
  end

  defp detect_n26_preset(csv_content) do
    csv_content
    |> Servant.Util.strip_bom()
    |> String.trim()
    |> String.split(~r/\r?\n/, parts: 2)
    |> case do
      [header | _] when is_binary(header) ->
        if String.contains?(header, "Booking Date") do
          @n26_modern
        else
          @n26_classic
        end

      _ ->
        @n26_classic
    end
  end

  defp do_parse(csv_content, preset) do
    lines =
      csv_content
      |> Servant.Util.strip_bom()
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

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
    row = zip_row(headers, values)

    raw_date = Map.get(row, preset.date_column, "")

    date =
      parse_date(raw_date, preset.date_format) ||
        parse_date(raw_date, :iso)

    description = build_description(row, preset)
    amount = parse_amount(Map.get(row, preset.amount_column, ""), preset.decimal_separator)

    currency =
      preset
      |> Map.get(:currency_column, "Currency")
      |> then(fn
        nil -> ""
        col -> Map.get(row, col, "")
      end)
      |> String.trim()

    balance =
      case Map.get(preset, :balance_column) do
        nil -> nil
        col -> parse_amount(Map.get(row, col, ""), preset.decimal_separator)
      end

    if date == nil or amount == nil or description == nil do
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

  defp zip_row(headers, values) do
    headers
    |> Enum.zip(values)
    |> Map.new()
  end

  defp build_description(row, %{description_columns: columns}) when is_list(columns) do
    columns
    |> Enum.map(fn col ->
      row
      |> Map.get(col, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " - ")
    end
  end

  defp build_description(row, %{description_column: column}) do
    case String.trim(Map.get(row, column, "")) do
      "" -> nil
      description -> description
    end
  end

  defp split_line(line, ",") do
    trimmed = String.trim(line)

    # `parse_string/1` defaults to `skip_headers: true`, which would consume this
    # single line as a header and return `[]`, so RFC4180 parsing never ran and
    # every comma-delimited line fell through to the naive splitter, mis-splitting
    # quoted fields that contain commas (e.g. "Smith, John"). Disable header
    # skipping so the one line is actually parsed.
    case NimbleCSV.RFC4180.parse_string(trimmed, skip_headers: false) do
      [fields | _] -> fields
      _ -> fallback_split(trimmed, ",")
    end
  end

  defp split_line(line, delimiter) do
    fallback_split(line, delimiter)
  end

  defp fallback_split(line, delimiter) do
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
      |> String.replace("€", "")

    str =
      case decimal_separator do
        "," ->
          str |> String.replace(".", "") |> String.replace(",", ".")

        _ ->
          String.replace(str, ",", "")
      end

    case Float.parse(str) do
      {val, _} -> val
      :error -> nil
    end
  end
end
