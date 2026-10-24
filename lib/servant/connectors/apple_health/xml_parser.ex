defmodule Servant.Connectors.AppleHealth.XMLParser do
  @moduledoc """
  SAX parser for the export.xml files of Apple Health.
  Streams the XML to handle large files (100MB+) and does not load the full content in memory.
  """

  @behaviour Saxy.Handler

  @doc """
  Parses an export XML string of Apple Health and returns a list of record maps.
  The parser does not aggregate. `AppleHealthConnector` groups the records per day.
  """
  def parse(xml_content) do
    case Saxy.parse_string(xml_content, __MODULE__, %{records: [], current: nil}) do
      {:ok, state} ->
        {:ok, state.records}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses from a file path. Uses a stream to keep the memory use low.
  """
  def parse_file(path) do
    case Saxy.parse_stream(File.stream!(path, 64 * 1024), __MODULE__, %{records: [], current: nil}) do
      {:ok, state} ->
        {:ok, state.records}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Saxy callbacks ---

  @impl Saxy.Handler
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_document, _data, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:start_element, {"Record", attrs}, state) do
    record = Map.new(attrs)
    {:ok, %{state | records: [record | state.records]}}
  end

  def handle_event(:start_element, {"Workout", attrs}, state) do
    record = attrs |> Map.new() |> Map.put("_tag", "Workout")
    {:ok, %{state | records: [record | state.records]}}
  end

  def handle_event(:start_element, _element, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:end_element, _name, state), do: {:ok, state}

  @impl Saxy.Handler
  def handle_event(:characters, _chars, state), do: {:ok, state}

  # --- Record type mapping ---

  @type_mapping %{
    "HKQuantityTypeIdentifierStepCount" => %{kind: "health", category: "steps", unit: "count"},
    "HKQuantityTypeIdentifierDistanceWalkingRunning" => %{
      kind: "health",
      category: "distance",
      unit: "km"
    },
    "HKQuantityTypeIdentifierHeartRate" => %{kind: "health", category: "heart_rate", unit: "bpm"},
    "HKQuantityTypeIdentifierRestingHeartRate" => %{
      kind: "health",
      category: "resting_heart_rate",
      unit: "bpm"
    },
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN" => %{
      kind: "health",
      category: "hrv",
      unit: "ms"
    },
    "HKQuantityTypeIdentifierActiveEnergyBurned" => %{
      kind: "health",
      category: "active_energy",
      unit: "kcal"
    },
    "HKQuantityTypeIdentifierBasalEnergyBurned" => %{
      kind: "health",
      category: "basal_energy",
      unit: "kcal"
    },
    "HKQuantityTypeIdentifierBodyMass" => %{kind: "health", category: "weight", unit: "kg"},
    "HKQuantityTypeIdentifierBodyMassIndex" => %{kind: "health", category: "bmi", unit: ""},
    "HKQuantityTypeIdentifierHeight" => %{kind: "health", category: "height", unit: "cm"},
    "HKQuantityTypeIdentifierBloodPressureSystolic" => %{
      kind: "health",
      category: "blood_pressure_systolic",
      unit: "mmHg"
    },
    "HKQuantityTypeIdentifierBloodPressureDiastolic" => %{
      kind: "health",
      category: "blood_pressure_diastolic",
      unit: "mmHg"
    },
    "HKQuantityTypeIdentifierOxygenSaturation" => %{kind: "health", category: "spo2", unit: "%"},
    "HKQuantityTypeIdentifierBodyTemperature" => %{
      kind: "health",
      category: "temperature",
      unit: "°C"
    },
    "HKQuantityTypeIdentifierRespiratoryRate" => %{
      kind: "health",
      category: "respiratory_rate",
      unit: "breaths/min"
    },
    "HKQuantityTypeIdentifierFlightsClimbed" => %{
      kind: "health",
      category: "flights_climbed",
      unit: "count"
    },
    "HKQuantityTypeIdentifierAppleExerciseTime" => %{
      kind: "health",
      category: "exercise_time",
      unit: "min"
    },
    "HKQuantityTypeIdentifierAppleStandTime" => %{
      kind: "health",
      category: "stand_time",
      unit: "min"
    },
    "HKCategoryTypeIdentifierSleepAnalysis" => %{kind: "health", category: "sleep", unit: ""},
    "HKQuantityTypeIdentifierDietaryWater" => %{kind: "health", category: "water", unit: "mL"},
    "HKQuantityTypeIdentifierDietaryEnergyConsumed" => %{
      kind: "health",
      category: "calories_consumed",
      unit: "kcal"
    },
    "HKQuantityTypeIdentifierVO2Max" => %{kind: "health", category: "vo2max", unit: "mL/kg·min"},
    "HKQuantityTypeIdentifierWalkingHeartRateAverage" => %{
      kind: "health",
      category: "walking_heart_rate",
      unit: "bpm"
    },
    "HKQuantityTypeIdentifierEnvironmentalAudioExposure" => %{
      kind: "health",
      category: "audio_exposure",
      unit: "dB"
    },
    "HKQuantityTypeIdentifierHeadphoneAudioExposure" => %{
      kind: "health",
      category: "headphone_audio",
      unit: "dB"
    }
  }

  def type_mapping, do: @type_mapping

  @doc """
  Converts a raw record map to a normalized structure.
  Returns nil for record types that are unknown or not of interest.
  """
  def normalize_record(record) do
    type = record["type"]

    case Map.get(@type_mapping, type) do
      nil ->
        # Handle workouts separately.
        if record["_tag"] == "Workout" do
          %{
            category: "workout",
            kind: "health",
            value: nil,
            unit: "min",
            workout_type: normalize_workout_type(record["workoutActivityType"]),
            duration: parse_float(record["duration"]),
            energy: parse_float(record["totalEnergyBurned"]),
            distance: parse_float(record["totalDistance"]),
            source: record["sourceName"] || "Apple Health",
            start_date: record["startDate"],
            end_date: record["endDate"]
          }
        else
          nil
        end

      mapping ->
        %{
          category: mapping.category,
          kind: mapping.kind,
          value: parse_float(record["value"]),
          unit: record["unit"] || mapping.unit,
          source: record["sourceName"] || "Apple Health",
          start_date: record["startDate"],
          end_date: record["endDate"]
        }
    end
  end

  defp normalize_workout_type(nil), do: "unknown"

  defp normalize_workout_type(type) do
    type
    |> String.replace("HKWorkoutActivityType", "")
    |> Macro.underscore()
  end

  defp parse_float(nil), do: nil

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(val), do: val

  @doc """
  Parses the date format of Apple Health ("2025-03-28 08:00:00 +0100") into a DateTime.
  """
  def parse_date(nil), do: nil

  def parse_date(str) do
    # Format: "2025-03-28 08:00:00 +0100"
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{4})$/, str) do
      [_, date_str, time_str, tz_offset] ->
        iso =
          "#{date_str}T#{time_str}#{String.slice(tz_offset, 0, 3)}:#{String.slice(tz_offset, 3, 2)}"

        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
          _ -> nil
        end

      _ ->
        # Try ISO8601 directly.
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> DateTime.truncate(dt, :second)
          _ -> nil
        end
    end
  end
end
