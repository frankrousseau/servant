defmodule Servant.Connectors.BankCSV.Parser do
  @moduledoc """
  Parses CSV files of bank transactions with configurable presets.
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
    },
    # Export "Téléchargement des opérations" (labanquepostale.fr). The file has
    # lines of account metadata above the real header, then
    # Date;Libellé;Montant(EUROS).
    "banque_postale" => %{
      delimiter: ";",
      date_column: "Date",
      description_column: "Libellé",
      amount_column: "Montant(EUROS)",
      currency_column: nil,
      balance_column: nil,
      date_format: :eu_slash,
      decimal_separator: ","
    },
    # CM-CIC export (cic.fr). The export screen gives split Débit/Crédit columns
    # or a single Montant column. The parser handles the two formats.
    "cic" => %{
      delimiter: ";",
      date_column: "Date",
      description_column: "Libellé",
      amount_column: "Montant",
      debit_column: "Débit",
      credit_column: "Crédit",
      currency_column: nil,
      balance_column: "Solde",
      date_format: :eu_slash,
      decimal_separator: ","
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
      |> ensure_utf8()
      |> Servant.Util.strip_bom()
      |> String.trim()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    case {lines, find_header(lines, preset)} do
      {[], _} ->
        {:error, "Empty CSV"}

      {_, nil} ->
        {:error,
         "Could not find the header row (expected a \"#{preset.date_column}\" column); " <>
           "check the bank format preset"}

      {_, {headers, data_lines}} ->
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

  # French bank exports (Banque Postale in particular) are Latin-1/Windows-1252.
  defp ensure_utf8(bin) do
    if String.valid?(bin), do: bin, else: :unicode.characters_to_binary(bin, :latin1)
  end

  # The header is the first line that contains the date column and a
  # description column. The Banque Postale exports put lines of account
  # metadata above it. One of them is a "Date ;<export date>" line, which a
  # match on the date column alone accepts.
  defp find_header(lines, preset) do
    description = preset[:description_column] || List.first(preset[:description_columns] || [])

    lines
    |> Enum.split_while(fn line ->
      fields = line |> split_line(preset.delimiter) |> Enum.map(&normalize_header/1)

      not (normalize_header(preset.date_column) in fields and
             normalize_header(description) in fields)
    end)
    |> case do
      {_preamble, [header | data_lines]} -> {split_line(header, preset.delimiter), data_lines}
      {_preamble, []} -> nil
    end
  end

  # The header spelling changes between export screens ("Montant(EUROS)" or
  # "Montant (EUROS)"). Ignore the spaces and the case when you compare and
  # store the header keys.
  defp normalize_header(nil), do: nil

  defp normalize_header(header) do
    header |> String.downcase() |> String.replace(" ", "")
  end

  defp parse_line(line, headers, preset, _line_num) do
    values = split_line(line, preset.delimiter)
    row = zip_row(headers, values)

    raw_date = row_get(row, preset.date_column)

    date =
      parse_date(raw_date, preset.date_format) ||
        parse_date(raw_date, :iso)

    description = build_description(row, preset)
    amount = row_amount(row, preset)

    currency =
      preset
      |> Map.get(:currency_column, "Currency")
      |> then(fn
        nil -> ""
        col -> row_get(row, col)
      end)
      |> String.trim()

    balance =
      case Map.get(preset, :balance_column) do
        nil -> nil
        col -> parse_amount(row_get(row, col), preset.decimal_separator)
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
    |> Enum.map(&normalize_header/1)
    |> Enum.zip(values)
    |> Map.new()
  end

  defp row_get(_row, nil), do: ""
  defp row_get(row, column), do: Map.get(row, normalize_header(column), "")

  # Split Débit/Crédit columns (CIC) have priority over a single amount
  # column. A debit is negative, whatever the sign in the bank export.
  defp row_amount(row, preset) do
    debit = parse_amount(row_get(row, preset[:debit_column]), preset.decimal_separator)
    credit = parse_amount(row_get(row, preset[:credit_column]), preset.decimal_separator)

    cond do
      is_number(debit) and debit != 0 -> -abs(debit)
      is_number(credit) -> abs(credit)
      true -> parse_amount(row_get(row, preset[:amount_column]), preset.decimal_separator)
    end
  end

  defp build_description(row, %{description_columns: columns}) when is_list(columns) do
    columns
    |> Enum.map(fn col ->
      row
      |> row_get(col)
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " - ")
    end
  end

  defp build_description(row, %{description_column: column}) do
    case String.trim(row_get(row, column)) do
      "" -> nil
      description -> description
    end
  end

  defp split_line(line, ",") do
    trimmed = String.trim(line)

    # The default of `parse_string/1` is `skip_headers: true`. That default
    # consumes this single line as a header and returns `[]`. As a result, the
    # RFC4180 parser never ran and every comma-delimited line went to the naive
    # splitter. That splitter splits quoted fields that contain commas (for
    # example "Smith, John") incorrectly. Disable the skip of headers so that
    # the parser parses the one line.
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

  # DD/MM/YYYY (French bank exports)
  defp parse_date(str, :eu_slash) do
    case Regex.run(~r|^(\d{2})/(\d{2})/(\d{4})$|, String.trim(str)) do
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
