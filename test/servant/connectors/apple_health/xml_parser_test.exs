defmodule Servant.Connectors.AppleHealth.XMLParserTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.AppleHealth.XMLParser

  @sample_xml ~s(<?xml version="1.0" encoding="UTF-8"?>
  <HealthData locale="en_US">
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone"
            startDate="2025-03-28 08:00:00 +0100" endDate="2025-03-28 09:00:00 +0100"
            value="1234" unit="count"/>
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone"
            startDate="2025-03-28 10:00:00 +0100" endDate="2025-03-28 11:00:00 +0100"
            value="567" unit="count"/>
    <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch"
            startDate="2025-03-28 10:00:00 +0100" endDate="2025-03-28 10:00:05 +0100"
            value="72" unit="count/min"/>
    <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch"
            startDate="2025-03-28 11:00:00 +0100" endDate="2025-03-28 11:00:05 +0100"
            value="80" unit="count/min"/>
    <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="iPhone"
            startDate="2025-03-28 07:00:00 +0100" endDate="2025-03-28 07:00:00 +0100"
            value="75.5" unit="kg"/>
    <Workout workoutActivityType="HKWorkoutActivityTypeRunning" sourceName="Apple Watch"
             duration="30.5" totalEnergyBurned="250.0" totalDistance="5.2"
             startDate="2025-03-28 18:00:00 +0100" endDate="2025-03-28 18:30:00 +0100"/>
  </HealthData>)

  describe "parse/1" do
    test "parses records from XML" do
      assert {:ok, records} = XMLParser.parse(@sample_xml)
      assert length(records) == 6
    end

    test "extracts record attributes" do
      {:ok, records} = XMLParser.parse(@sample_xml)
      steps = Enum.filter(records, &(&1["type"] == "HKQuantityTypeIdentifierStepCount"))
      assert length(steps) == 2
      values = Enum.map(steps, & &1["value"]) |> Enum.sort()
      assert values == ["1234", "567"]
      assert Enum.all?(steps, &(&1["sourceName"] == "iPhone"))
    end

    test "extracts workout attributes" do
      {:ok, records} = XMLParser.parse(@sample_xml)
      workout = Enum.find(records, &(&1["_tag"] == "Workout"))
      assert workout["workoutActivityType"] == "HKWorkoutActivityTypeRunning"
      assert workout["duration"] == "30.5"
    end
  end

  describe "normalize_record/1" do
    test "normalizes step count record" do
      record = %{
        "type" => "HKQuantityTypeIdentifierStepCount",
        "value" => "1234",
        "unit" => "count",
        "sourceName" => "iPhone",
        "startDate" => "2025-03-28 08:00:00 +0100",
        "endDate" => "2025-03-28 09:00:00 +0100"
      }

      result = XMLParser.normalize_record(record)
      assert result.category == "steps"
      assert result.value == 1234.0
    end

    test "normalizes heart rate record" do
      record = %{
        "type" => "HKQuantityTypeIdentifierHeartRate",
        "value" => "72",
        "unit" => "count/min",
        "sourceName" => "Apple Watch",
        "startDate" => "2025-03-28 10:00:00 +0100",
        "endDate" => "2025-03-28 10:00:05 +0100"
      }

      result = XMLParser.normalize_record(record)
      assert result.category == "heart_rate"
      assert result.value == 72.0
    end

    test "normalizes workout" do
      record = %{
        "_tag" => "Workout",
        "workoutActivityType" => "HKWorkoutActivityTypeRunning",
        "duration" => "30.5",
        "totalEnergyBurned" => "250.0",
        "totalDistance" => "5.2",
        "sourceName" => "Apple Watch",
        "startDate" => "2025-03-28 18:00:00 +0100",
        "endDate" => "2025-03-28 18:30:00 +0100"
      }

      result = XMLParser.normalize_record(record)
      assert result.category == "workout"
      assert result.workout_type == "running"
      assert result.duration == 30.5
    end

    test "returns nil for unknown record type" do
      record = %{"type" => "HKSomethingUnknown", "value" => "1"}
      assert is_nil(XMLParser.normalize_record(record))
    end
  end

  describe "parse_date/1" do
    test "parses Apple Health date format" do
      assert %DateTime{year: 2025, month: 3, day: 28, hour: 7} =
               XMLParser.parse_date("2025-03-28 08:00:00 +0100")
    end

    test "returns nil for nil" do
      assert is_nil(XMLParser.parse_date(nil))
    end
  end
end
