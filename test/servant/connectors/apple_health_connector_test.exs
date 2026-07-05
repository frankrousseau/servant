defmodule Servant.Connectors.AppleHealthConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.AppleHealthConnector

  @sample_xml ~s(<?xml version="1.0" encoding="UTF-8"?>
  <HealthData locale="en_US">
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone"
            startDate="2025-03-28 08:00:00 +0100" endDate="2025-03-28 09:00:00 +0100"
            value="3000" unit="count"/>
    <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone"
            startDate="2025-03-28 14:00:00 +0100" endDate="2025-03-28 15:00:00 +0100"
            value="5000" unit="count"/>
    <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch"
            startDate="2025-03-28 10:00:00 +0100" endDate="2025-03-28 10:00:05 +0100"
            value="72" unit="count/min"/>
    <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch"
            startDate="2025-03-28 14:00:00 +0100" endDate="2025-03-28 14:00:05 +0100"
            value="80" unit="count/min"/>
    <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="iPhone"
            startDate="2025-03-28 07:00:00 +0100" endDate="2025-03-28 07:00:00 +0100"
            value="75.5" unit="kg"/>
    <Workout workoutActivityType="HKWorkoutActivityTypeRunning" sourceName="Apple Watch"
             duration="30.5" totalEnergyBurned="250.0" totalDistance="5.2"
             startDate="2025-03-28 18:00:00 +0100" endDate="2025-03-28 18:30:00 +0100"/>
  </HealthData>)

  describe "import_health/2" do
    test "parses and aggregates records into entries" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries} = AppleHealthConnector.import_health(@sample_xml, state)

      # Should get: steps (sum), heart_rate (avg), weight (latest), workout
      assert length(entries) == 4

      kinds = entries |> Enum.map(& &1["kind"]) |> Enum.uniq()
      assert kinds == ["health"]

      sources = entries |> Enum.map(& &1["source"]) |> Enum.uniq()
      assert sources == ["apple_health"]
    end

    test "aggregates steps by day (sum)" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries} = AppleHealthConnector.import_health(@sample_xml, state)

      steps = Enum.find(entries, &(&1["data"]["category"] == "steps"))
      assert steps["data"]["value"] == 8000.0
      assert String.contains?(steps["title"], "8000")
    end

    test "aggregates heart rate by day (average)" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries} = AppleHealthConnector.import_health(@sample_xml, state)

      hr = Enum.find(entries, &(&1["data"]["category"] == "heart_rate"))
      assert hr["data"]["value"] == 76.0
      assert hr["data"]["sample_count"] == 2
    end

    test "keeps weight as latest value" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries} = AppleHealthConnector.import_health(@sample_xml, state)

      weight = Enum.find(entries, &(&1["data"]["category"] == "weight"))
      assert weight["data"]["value"] == 75.5
      assert String.contains?(weight["title"], "75.5")
    end

    test "creates workout entry" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries} = AppleHealthConnector.import_health(@sample_xml, state)

      workout = Enum.find(entries, &(&1["data"]["category"] == "workout"))
      assert workout["data"]["workout_type"] == "running"
      assert workout["data"]["duration"] == 30.5
      assert String.contains?(workout["title"], "Running")
    end

    test "uses deterministic external_ids for dedup" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      {:ok, entries1} = AppleHealthConnector.import_health(@sample_xml, state)
      {:ok, entries2} = AppleHealthConnector.import_health(@sample_xml, state)

      ids1 = entries1 |> Enum.map(& &1["external_id"]) |> Enum.sort()
      ids2 = Enum.map(entries2, & &1["external_id"]) |> Enum.sort()
      assert ids1 == ids2
    end
  end

  describe "metadata" do
    test "id is apple_health" do
      assert AppleHealthConnector.id() == "apple_health"
    end

    test "kind is health" do
      assert AppleHealthConnector.kind() == "health"
    end

    test "only supports on_demand" do
      assert AppleHealthConnector.supported_schedules() == ["on_demand"]
    end

    test "sync returns empty (import-only)" do
      {:ok, state} = AppleHealthConnector.init(%{}, %{})
      assert {:ok, [], ^state} = AppleHealthConnector.sync(state)
    end
  end
end
