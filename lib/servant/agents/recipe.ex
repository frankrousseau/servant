defmodule Servant.Agents.Recipe do
  @moduledoc """
  Declarative recipe for deterministic recurring agents: a fixed-shape,
  strictly validated JSON object (where / group_by / aggregate / emit_if)
  interpreted in memory over the agent's entry window. No model call at
  run time; the LLM only drafts the recipe at authoring time.
  """

  @known_keys ~w(where group_by aggregate emit_if)
  @filter_ops ~w(eq neq contains gt gte lt lte exists)
  @numeric_ops ~w(gt gte lt lte)
  @aggregate_ops ~w(sum avg count min max last)
  @emit_ops ~w(eq neq gt gte lt lte)
  @time_buckets ~w(day week month)
  @field_re ~r/^(title|source|occurred_at|data\.[a-zA-Z0-9_][a-zA-Z0-9_.-]*|metadata\.[a-zA-Z0-9_][a-zA-Z0-9_.-]*)$/

  # ----- validation -----

  def validate(recipe) when is_map(recipe) do
    with :ok <- validate_keys(recipe),
         :ok <- validate_where(Map.get(recipe, "where")),
         :ok <- validate_group_by(Map.get(recipe, "group_by")),
         :ok <- validate_aggregate(Map.get(recipe, "aggregate")) do
      validate_emit_if(Map.get(recipe, "emit_if"), recipe)
    end
  end

  def validate(_recipe), do: {:error, "recipe must be a JSON object"}

  defp validate_keys(recipe) do
    case Map.keys(recipe) -- @known_keys do
      [] -> :ok
      extra -> {:error, "unknown recipe keys: #{Enum.join(extra, ", ")}"}
    end
  end

  defp validate_where(nil), do: :ok

  defp validate_where(conditions) when is_list(conditions) do
    Enum.find_value(conditions, :ok, fn condition ->
      case validate_condition(condition) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp validate_where(_), do: {:error, "where must be a list of conditions"}

  defp validate_condition(%{"field" => field, "op" => op} = condition) when is_binary(field) do
    cond do
      Map.keys(condition) -- ~w(field op value) != [] ->
        {:error, "a condition only has field, op and value"}

      not Regex.match?(@field_re, field) ->
        {:error, "field #{field} is not allowed"}

      op not in @filter_ops ->
        {:error, "unknown filter op #{inspect(op)}"}

      op == "exists" and Map.has_key?(condition, "value") ->
        {:error, "exists takes no value"}

      op != "exists" and not Map.has_key?(condition, "value") ->
        {:error, "op #{op} needs a value"}

      op in @numeric_ops and not valid_numeric_value?(condition["value"]) ->
        {:error, "op #{op} needs a number or an ISO date string"}

      op == "contains" and not is_binary(condition["value"]) ->
        {:error, "contains needs a string value"}

      true ->
        :ok
    end
  end

  defp validate_condition(_), do: {:error, "each condition needs field and op"}

  defp valid_numeric_value?(value) when is_number(value), do: true

  defp valid_numeric_value?(value) when is_binary(value) do
    # ISO date strings start with digits; reject arbitrary strings like "high"
    value != "" and String.at(value, 0) in ~w(0 1 2 3 4 5 6 7 8 9)
  end

  defp valid_numeric_value?(_), do: false

  defp validate_group_by(nil), do: :ok

  defp validate_group_by(group) when is_binary(group) do
    if group in @time_buckets or Regex.match?(@field_re, group) do
      :ok
    else
      {:error, "group_by must be a field path or day/week/month"}
    end
  end

  defp validate_group_by(_), do: {:error, "group_by must be a string"}

  defp validate_aggregate(nil), do: :ok

  defp validate_aggregate(%{"op" => op} = aggregate) do
    cond do
      Map.keys(aggregate) -- ~w(op field) != [] ->
        {:error, "aggregate only has op and field"}

      op not in @aggregate_ops ->
        {:error, "unknown aggregate op #{inspect(op)}"}

      op == "count" and Map.has_key?(aggregate, "field") ->
        {:error, "count takes no field"}

      op != "count" and
          not (is_binary(aggregate["field"]) and Regex.match?(@field_re, aggregate["field"])) ->
        {:error, "aggregate #{op} needs an allowed field path"}

      true ->
        :ok
    end
  end

  defp validate_aggregate(_), do: {:error, "aggregate must be an object with an op"}

  defp validate_emit_if(nil, _recipe), do: :ok

  defp validate_emit_if(%{"op" => op, "value" => value} = emit, recipe) do
    cond do
      Map.keys(emit) -- ~w(op value) != [] ->
        {:error, "emit_if only has op and value"}

      op not in @emit_ops ->
        {:error, "emit_if op must be a comparison (#{Enum.join(@emit_ops, ", ")})"}

      not is_number(value) ->
        {:error, "emit_if value must be a number"}

      Map.get(recipe, "aggregate") == nil ->
        {:error, "emit_if needs an aggregate"}

      Map.get(recipe, "group_by") != nil ->
        {:error, "emit_if cannot be combined with group_by"}

      true ->
        :ok
    end
  end

  defp validate_emit_if(_, _recipe), do: {:error, "emit_if must be an object with op and value"}

  # ----- interpretation -----

  @doc """
  Interprets a validated recipe over the window's entries (assumed sorted
  by occurred_at desc). Returns {:ok, markdown} or :skip when emit_if is
  false.
  """
  def run(recipe, entries) do
    filtered = apply_where(entries, Map.get(recipe, "where"))

    case Map.get(recipe, "aggregate") do
      nil ->
        {:ok, digest(filtered)}

      aggregate ->
        case Map.get(recipe, "group_by") do
          nil -> single(recipe, aggregate, filtered)
          group -> {:ok, table(group, aggregate, filtered)}
        end
    end
  end

  defp apply_where(entries, nil), do: entries

  defp apply_where(entries, conditions) do
    Enum.filter(entries, fn entry ->
      Enum.all?(conditions, fn condition ->
        matches?(get_path(entry, condition["field"]), condition["op"], condition["value"])
      end)
    end)
  end

  defp matches?(value, "exists", _), do: not is_nil(value)
  defp matches?(nil, _op, _value), do: false

  defp matches?(%DateTime{} = value, op, expected),
    do: matches?(DateTime.to_iso8601(value), op, expected)

  defp matches?(value, "eq", expected), do: value == expected
  defp matches?(value, "neq", expected), do: value != expected

  defp matches?(value, "contains", expected) when is_binary(value) and is_binary(expected),
    do: String.contains?(value, expected)

  defp matches?(value, op, expected)
       when op in @numeric_ops and
              ((is_number(value) and is_number(expected)) or
                 (is_binary(value) and is_binary(expected))) do
    case op do
      "gt" -> value > expected
      "gte" -> value >= expected
      "lt" -> value < expected
      "lte" -> value <= expected
    end
  end

  defp matches?(_value, _op, _expected), do: false

  defp get_path(entry, "title"), do: entry.title
  defp get_path(entry, "source"), do: entry.source
  defp get_path(entry, "occurred_at"), do: entry.occurred_at
  defp get_path(entry, "data." <> rest), do: dig(entry.data, String.split(rest, "."))
  defp get_path(entry, "metadata." <> rest), do: dig(entry.metadata, String.split(rest, "."))
  defp get_path(_entry, _field), do: nil

  defp dig(value, []), do: value
  defp dig(map, [key | rest]) when is_map(map), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  # ----- aggregates -----

  defp single(recipe, aggregate, entries) do
    value = aggregate_value(aggregate, entries)

    if emit?(Map.get(recipe, "emit_if"), value) do
      label = aggregate_label(aggregate)
      {:ok, "#{label}: #{fmt(value)}\n\n(#{entries_count(length(entries))} considered)"}
    else
      :skip
    end
  end

  defp emit?(nil, _value), do: true
  defp emit?(_emit, nil), do: false
  # Erlang term order would otherwise make gt always emit and lt never for a
  # non-numeric value (e.g. "last" on a string field); never emit instead.
  defp emit?(_emit, value) when not is_number(value), do: false

  defp emit?(%{"op" => op, "value" => expected}, value) do
    case op do
      "eq" -> value == expected
      "neq" -> value != expected
      "gt" -> value > expected
      "gte" -> value >= expected
      "lt" -> value < expected
      "lte" -> value <= expected
    end
  end

  defp aggregate_value(%{"op" => "count"}, entries), do: length(entries)

  defp aggregate_value(%{"op" => "last", "field" => field}, entries) do
    Enum.find_value(entries, fn entry -> get_path(entry, field) end)
  end

  defp aggregate_value(%{"op" => op, "field" => field}, entries) do
    numbers = for entry <- entries, value = get_path(entry, field), is_number(value), do: value

    case {op, numbers} do
      {"sum", numbers} -> Enum.sum(numbers)
      {_op, []} -> nil
      {"avg", numbers} -> Enum.sum(numbers) / length(numbers)
      {"min", numbers} -> Enum.min(numbers)
      {"max", numbers} -> Enum.max(numbers)
    end
  end

  defp aggregate_label(%{"op" => "count"}), do: "count"
  defp aggregate_label(%{"op" => op, "field" => field}), do: "#{op}(#{field})"

  defp entries_count(1), do: "1 entry"
  defp entries_count(n), do: "#{n} entries"

  defp fmt(nil), do: "no data"
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)

  defp fmt(value) when is_float(value),
    do: :erlang.float_to_binary(Float.round(value, 2), decimals: 2)

  defp fmt(value), do: to_string(value)

  # ----- grouped table -----

  defp table(group, aggregate, entries) do
    time_bucket? = group in @time_buckets

    rows =
      entries
      |> Enum.group_by(&group_key(&1, group, time_bucket?))
      |> Enum.reject(fn {key, _} -> time_bucket? and key == nil end)
      |> Enum.map(fn {key, grouped} -> {key || "-", aggregate_value(aggregate, grouped)} end)
      |> sort_rows(time_bucket?)

    if rows == [] do
      "(no entries)"
    else
      header = "| #{group} | #{aggregate_label(aggregate)} |\n| --- | --- |"
      body = Enum.map_join(rows, "\n", fn {key, value} -> "| #{key} | #{fmt(value)} |" end)
      header <> "\n" <> body
    end
  end

  defp group_key(entry, group, false) do
    case get_path(entry, group) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp group_key(entry, bucket, true) do
    case entry.occurred_at do
      nil -> nil
      occurred_at -> bucket_label(DateTime.to_date(occurred_at), bucket)
    end
  end

  defp bucket_label(date, "day"), do: Date.to_iso8601(date)
  defp bucket_label(date, "month"), do: String.slice(Date.to_iso8601(date), 0, 7)

  defp bucket_label(date, "week") do
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp sort_rows(rows, true), do: Enum.sort_by(rows, fn {key, _} -> key end)

  defp sort_rows(rows, false) do
    if Enum.all?(rows, fn {_, value} -> is_number(value) end) do
      Enum.sort_by(rows, fn {_, value} -> value end, :desc)
    else
      Enum.sort_by(rows, fn {key, _} -> key end)
    end
  end

  # ----- digest -----

  defp digest([]), do: "(no entries)"

  defp digest(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      date = (entry.occurred_at && Date.to_iso8601(DateTime.to_date(entry.occurred_at))) || "-"
      "- #{date} | #{entry.title || "-"}"
    end)
  end
end
