defmodule Servant.CalDAV.ICSTest do
  use ExUnit.Case, async: true

  alias Servant.CalDAV.ICS
  alias Servant.Data.Entry

  @timed_ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Apple Inc.//iOS 19.0//EN
  BEGIN:VEVENT
  UID:ABC-123
  DTSTAMP:20260713T120000Z
  DTSTART;TZID=Europe/Paris:20260715T100000
  DTEND;TZID=Europe/Paris:20260715T110000
  SUMMARY:Dentiste\\, contrôle
  LOCATION:12 rue du Bac
  DESCRIPTION:Ligne 1\\nLigne 2
  END:VEVENT
  END:VCALENDAR
  """

  describe "parse_event/2" do
    test "timed event with TZID converts to UTC and user wall clock" do
      {:ok, parsed} = ICS.parse_event(@timed_ics, "Europe/Paris")

      assert parsed.uid == "ABC-123"
      assert parsed.title == "Dentiste, contrôle"
      assert parsed.occurred_at == ~U[2026-07-15 08:00:00Z]
      assert parsed.data["dtstart"] == "20260715T100000"
      assert parsed.data["dtend"] == "20260715T110000"
      assert parsed.data["end_at"] == "2026-07-15T09:00:00Z"
      assert parsed.data["all_day"] == false
      assert parsed.data["location"] == "12 rue du Bac"
      assert parsed.data["description"] == "Ligne 1\nLigne 2"
    end

    test "wall clock follows the user timezone, not the event TZID" do
      {:ok, parsed} = ICS.parse_event(@timed_ics, "Etc/UTC")

      assert parsed.data["dtstart"] == "20260715T080000"
    end

    test "all-day event stores date-only bounds with inclusive end" do
      ics = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:allday-1
      DTSTART;VALUE=DATE:20260714
      DTEND;VALUE=DATE:20260716
      SUMMARY:Deux jours
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, parsed} = ICS.parse_event(ics, "Europe/Paris")

      assert parsed.data["all_day"] == true
      assert parsed.data["dtstart"] == "20260714"
      assert parsed.data["dtend"] == "20260715"
      # Midnight Paris on the 14th
      assert parsed.occurred_at == ~U[2026-07-13 22:00:00Z]
      assert parsed.data["end_at"] == "2026-07-15T21:59:00Z"
    end

    test "UTC datetimes and floating datetimes" do
      ics = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:u1
      DTSTART:20260715T100000Z
      SUMMARY:UTC
      END:VEVENT
      END:VCALENDAR
      """

      {:ok, parsed} = ICS.parse_event(ics, "Europe/Paris")
      assert parsed.occurred_at == ~U[2026-07-15 10:00:00Z]

      floating = String.replace(ics, "100000Z", "100000")
      {:ok, parsed} = ICS.parse_event(floating, "Europe/Paris")
      assert parsed.occurred_at == ~U[2026-07-15 08:00:00Z]
    end

    test "bare FREQ rules map to the app recurrence, richer rules do not" do
      base = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:r1
      DTSTART:20260715T100000Z
      SUMMARY:R
      RRULE:%RRULE%
      END:VEVENT
      END:VCALENDAR
      """

      parse = fn rrule ->
        {:ok, parsed} = base |> String.replace("%RRULE%", rrule) |> ICS.parse_event("Etc/UTC")
        parsed.data["recurrence"]
      end

      assert parse.("FREQ=YEARLY") == "yearly"
      assert parse.("FREQ=WEEKLY;INTERVAL=1") == "weekly"
      assert parse.("FREQ=WEEKLY;BYDAY=MO") == nil
      assert parse.("FREQ=DAILY") == nil
    end

    test "rejects payloads without VEVENT or DTSTART" do
      assert {:error, _} = ICS.parse_event("BEGIN:VCALENDAR\nEND:VCALENDAR\n", "Etc/UTC")

      no_start = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:x
      SUMMARY:Sans début
      END:VEVENT
      END:VCALENDAR
      """

      assert {:error, _} = ICS.parse_event(no_start, "Etc/UTC")
    end
  end

  describe "to_ics/2" do
    test "synthesizes a timed VEVENT from entry fields" do
      entry = %Entry{
        id: "11111111-2222-3333-4444-555555555555",
        title: "Réunion, importante",
        occurred_at: ~U[2026-07-15 08:00:00Z],
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: nil,
        data: %{
          "end_at" => "2026-07-15T09:00:00Z",
          "location" => "Salle A",
          "recurrence" => "weekly"
        }
      }

      ics = ICS.to_ics(entry, "Europe/Paris")

      assert ics =~ "UID:11111111-2222-3333-4444-555555555555@servant"
      assert ics =~ "SUMMARY:Réunion\\, importante"
      assert ics =~ "DTSTART:20260715T080000Z"
      assert ics =~ "DTEND:20260715T090000Z"
      assert ics =~ "LOCATION:Salle A"
      assert ics =~ "RRULE:FREQ=WEEKLY"
    end

    test "synthesizes all-day VEVENT with exclusive DTEND" do
      entry = %Entry{
        id: "id",
        title: "Vacances",
        occurred_at: ~U[2026-07-13 22:00:00Z],
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: nil,
        data: %{"all_day" => true, "dtstart" => "20260714", "dtend" => "20260715"}
      }

      ics = ICS.to_ics(entry, "Europe/Paris")

      assert ics =~ "DTSTART;VALUE=DATE:20260714"
      assert ics =~ "DTEND;VALUE=DATE:20260716"
    end

    test "returns the stored raw ICS while the entry is untouched" do
      raw = "BEGIN:VCALENDAR\r\nRAW\r\nEND:VCALENDAR\r\n"

      entry = %Entry{
        id: "id",
        title: "T",
        occurred_at: ~U[2026-07-15 08:00:00Z],
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: "abc",
        data: %{"caldav_ics" => raw, "caldav_ics_at" => "2026-07-13T10:00:00Z"}
      }

      assert ICS.to_ics(entry, "Etc/UTC") == raw

      stale = %{entry | updated_at: ~U[2026-07-13 11:00:00Z]}
      regenerated = ICS.to_ics(stale, "Etc/UTC")
      assert regenerated =~ "BEGIN:VEVENT"
      assert regenerated =~ "UID:abc"
    end
  end
end
