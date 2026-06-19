defmodule Servant.Connectors.ICalConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.ICalConnector

  @sample_ical """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:event1@example.com
  DTSTART:20250315T100000Z
  DTEND:20250315T110000Z
  SUMMARY:Team standup
  DESCRIPTION:Daily sync with the team
  LOCATION:Zoom
  END:VEVENT
  BEGIN:VEVENT
  UID:event2@example.com
  DTSTART:20250320
  SUMMARY:Company offsite
  DESCRIPTION:Full day\\, all hands
  LOCATION:Paris
  END:VEVENT
  BEGIN:VEVENT
  UID:event3@example.com
  DTSTART:20250401T140000
  DTEND:20250401T150000
  SUMMARY:Dentist appointment
  END:VEVENT
  END:VCALENDAR
  """

  describe "parse_ical/1" do
    test "parses events from iCal content" do
      events = ICalConnector.parse_ical(@sample_ical)
      assert length(events) == 3
    end

    test "extracts summary, description, location, uid" do
      [event | _] = ICalConnector.parse_ical(@sample_ical)
      assert event[:summary] == "Team standup"
      assert event[:description] == "Daily sync with the team"
      assert event[:location] == "Zoom"
      assert event[:uid] == "event1@example.com"
    end

    test "extracts dtstart and dtend" do
      [event | _] = ICalConnector.parse_ical(@sample_ical)
      assert event[:dtstart] == "20250315T100000Z"
      assert event[:dtend] == "20250315T110000Z"
    end

    test "unescapes description" do
      [_, event | _] = ICalConnector.parse_ical(@sample_ical)
      assert event[:description] == "Full day, all hands"
    end
  end

  describe "parse_ical_datetime/1" do
    test "parses UTC datetime (Z suffix)" do
      assert {:ok, dt} = ICalConnector.parse_ical_datetime("20250315T100000Z")
      assert dt == ~U[2025-03-15 10:00:00Z]
    end

    test "parses datetime without timezone as UTC" do
      assert {:ok, dt} = ICalConnector.parse_ical_datetime("20250401T140000")
      assert dt == ~U[2025-04-01 14:00:00Z]
    end

    test "parses date-only value" do
      assert {:ok, dt} = ICalConnector.parse_ical_datetime("20250320")
      assert dt == ~U[2025-03-20 00:00:00Z]
    end

    test "returns error for nil" do
      assert {:error, nil} = ICalConnector.parse_ical_datetime(nil)
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_format} = ICalConnector.parse_ical_datetime("not-a-date")
    end
  end

  describe "init/2" do
    test "succeeds with url" do
      assert {:ok, state} = ICalConnector.init(%{}, %{"url" => "https://example.com/cal.ics"})
      assert state.url == "https://example.com/cal.ics"
      assert state.calendar_name == "Calendar"
    end

    test "accepts custom calendar name" do
      assert {:ok, state} =
               ICalConnector.init(%{}, %{
                 "url" => "https://x.com/c.ics",
                 "calendar_name" => "Work"
               })

      assert state.calendar_name == "Work"
    end

    test "succeeds without url (import-only mode)" do
      assert {:ok, state} = ICalConnector.init(%{}, %{})
      assert state.url == nil
      assert state.calendar_name == "Calendar"
    end
  end

  describe "metadata" do
    test "id is ical" do
      assert ICalConnector.id() == "ical"
    end

    test "kind is event" do
      assert ICalConnector.kind() == "event"
    end

    test "default schedule is every_hour" do
      assert ICalConnector.default_schedule() == "every_hour"
    end
  end

  describe "line unfolding" do
    test "handles folded lines" do
      ical =
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:fold@test\r\nDTSTART:20250315T100000Z\r\nSUMMARY:This is a very long\r\n  summary that wraps\r\nEND:VEVENT\r\nEND:VCALENDAR"

      [event] = ICalConnector.parse_ical(ical)
      assert event[:summary] == "This is a very long summary that wraps"
    end
  end
end
