defmodule Servant.Connectors.AppleHealthConnector do
  @moduledoc """
  Import connector for Apple Health export.xml files.
  On-demand only: the user exports their health data from iOS
  (Settings → Health → Export All Health Data) and uploads the XML.

  Records are aggregated by category and day to avoid creating
  thousands of entries for high-frequency data (e.g. heart rate).
  """

  use Servant.Connectors.Connector

  alias Servant.Connectors.AppleHealth.XMLParser

  @impl true
  def id, do: "apple_health"

  @impl true
  def name, do: "Apple Health"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "health"

  @impl true
  def supported_schedules, do: ~w(on_demand)

  @impl true
  def default_schedule, do: "on_demand"

  @impl true
  def init(_credentials, _config) do
    {:ok, %{}}
  end

  @impl true
  def sync(state) do
    # Import-only connector
    {:ok, [], state}
  end

  @doc """
  Parses Apple Health export XML and returns entry maps.
  Aggregates high-frequency data (steps, heart rate, etc.) by day.
  """
  def import_health(xml_content, _state) do
    case XMLParser.parse(xml_content) do
      {:ok, raw_records} ->
        entries =
          raw_records
          |> Enum.map(&XMLParser.normalize_record/1)
          |> Enum.reject(&is_nil/1)
          |> aggregate_by_day()
          |> Enum.map(&build_entry/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, "Failed to parse XML: #{inspect(reason)}"}
    end
  end

  # --- Aggregation ---

  # High-frequency categories that should be aggregated per day
  @aggregate_categories ~w(steps distance active_energy basal_energy exercise_time stand_time
                           flights_climbed water calories_consumed)

  # Categories where we want the daily average
  @average_categories ~w(heart_rate resting_heart_rate hrv walking_heart_rate
                         respiratory_rate spo2 audio_exposure headphone_audio)

  defp aggregate_by_day(records) do
    records
    |> Enum.group_by(fn record ->
      date = XMLParser.parse_date(record.start_date)
      day = if date, do: DateTime.to_date(date), else: Date.utc_today()
      {record.category, day}
    end)
    |> Enum.map(fn {{category, day}, day_records} ->
      cond do
        category == "workout" ->
          # Don't aggregate workouts, keep each one
          Enum.map(day_records, &{category, day, &1})

        category in @aggregate_categories ->
          [{category, day, sum_records(day_records, day)}]

        category in @average_categories ->
          [{category, day, avg_records(day_records, day)}]

        true ->
          # Single-value categories (weight, height, etc.): take latest
          latest = Enum.max_by(day_records, & &1.start_date, fn -> List.first(day_records) end)
          [{category, day, latest}]
      end
    end)
    |> List.flatten()
  end

  defp sum_records(records, _day) do
    total = records |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1) |> Enum.sum()
    sample = List.first(records)
    %{sample | value: total}
  end

  defp avg_records(records, _day) do
    values = records |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)

    avg =
      if values != [] do
        Float.round(Enum.sum(values) / length(values), 1)
      else
        nil
      end

    sample = List.first(records)
    count = length(values)
    Map.put(%{sample | value: avg}, :sample_count, count)
  end

  # --- Entry builder ---

  defp build_entry({category, day, record}) when category == "workout" do
    workout_name =
      (record.workout_type || "workout") |> String.replace("_", " ") |> String.capitalize()

    duration_min = if record.duration, do: trunc(Float.round(record.duration, 0)), else: nil

    title =
      [
        workout_name,
        if(duration_min, do: "#{duration_min} min"),
        if(record.distance, do: "#{Float.round(record.distance, 1)} km")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")

    %{
      "kind" => "health",
      "source" => "apple_health",
      "external_id" => "workout-#{day}-#{record.workout_type}-#{record.start_date}",
      "title" => title,
      "occurred_at" => date_to_datetime(day),
      "data" => %{
        "category" => "workout",
        "workout_type" => record.workout_type,
        "duration" => record.duration,
        "energy" => record.energy,
        "distance" => record.distance,
        "source_device" => record.source,
        "start_date" => record.start_date,
        "end_date" => record.end_date
      },
      "metadata" => %{}
    }
  end

  defp build_entry({category, day, record}) do
    title = build_title(category, record)

    %{
      "kind" => "health",
      "source" => "apple_health",
      "external_id" => "#{category}-#{day}",
      "title" => title,
      "occurred_at" => date_to_datetime(day),
      "data" => %{
        "category" => category,
        "value" => record.value,
        "unit" => record[:unit],
        "sample_count" => record[:sample_count],
        "source_device" => record.source
      },
      "metadata" => %{}
    }
  end

  defp build_title("steps", record), do: "#{format_number(record.value)} steps"
  defp build_title("distance", record), do: "#{format_decimal(record.value, 1)} km walked"

  defp build_title("heart_rate", record),
    do: "Heart rate avg #{format_decimal(record.value, 0)} bpm"

  defp build_title("resting_heart_rate", record),
    do: "Resting HR #{format_decimal(record.value, 0)} bpm"

  defp build_title("hrv", record), do: "HRV #{format_decimal(record.value, 0)} ms"
  defp build_title("active_energy", record), do: "#{format_number(record.value)} kcal active"
  defp build_title("basal_energy", record), do: "#{format_number(record.value)} kcal basal"
  defp build_title("weight", record), do: "Weight #{format_decimal(record.value, 1)} kg"
  defp build_title("exercise_time", record), do: "#{format_number(record.value)} min exercise"
  defp build_title("stand_time", record), do: "#{format_number(record.value)} min standing"

  defp build_title("flights_climbed", record),
    do: "#{format_number(record.value)} flights climbed"

  defp build_title("sleep", _record), do: "Sleep"
  defp build_title("spo2", record), do: "SpO2 #{format_decimal(record.value, 0)}%"
  defp build_title("vo2max", record), do: "VO2 Max #{format_decimal(record.value, 1)}"
  defp build_title("water", record), do: "#{format_number(record.value)} mL water"

  defp build_title(category, record) do
    value_str = if record.value, do: " #{record.value}", else: ""
    unit_str = if record[:unit] && record[:unit] != "", do: " #{record[:unit]}", else: ""
    "#{category |> String.replace("_", " ") |> String.capitalize()}#{value_str}#{unit_str}"
  end

  defp format_number(nil), do: "0"
  defp format_number(val) when is_float(val), do: val |> trunc() |> Integer.to_string()
  defp format_number(val), do: to_string(val)

  defp format_decimal(nil, _), do: "0"

  defp format_decimal(val, decimals) when is_float(val),
    do: :erlang.float_to_binary(val, decimals: decimals)

  defp format_decimal(val, _), do: to_string(val)

  defp date_to_datetime(date) do
    DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
  end
end
