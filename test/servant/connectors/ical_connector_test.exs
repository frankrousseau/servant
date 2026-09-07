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

    test "returns error (not a crash) for well-shaped but invalid stamps" do
      # These match the digit-shape regexes but are out of range; the parser must
      # not raise (a single bad VEVENT would otherwise take down the worker).
      assert {:error, :invalid_format} = ICalConnector.parse_ical_datetime("20250230T120000Z")
      assert {:error, :invalid_format} = ICalConnector.parse_ical_datetime("20250401T240000Z")
      assert {:error, :invalid_format} = ICalConnector.parse_ical_datetime("20251340")
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

  describe "sync/1" do
    # A public IP literal, so the SSRF guard resolves without a DNS lookup and
    # the test stays offline; Req.Test answers the request itself.
    @feed_url "http://93.184.216.34/calendar.ics"

    defp state(config \\ %{}) do
      {:ok, state} = ICalConnector.init(%{}, Map.merge(%{"url" => @feed_url}, config))
      state
    end

    test "turns the calendar into event entries" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, @sample_ical) end)

      assert {:ok, entries, _state} = ICalConnector.sync(state(%{"calendar_name" => "Work"}))
      assert length(entries) == 3

      [standup | _] = entries
      assert standup["kind"] == "event"
      assert standup["source"] == "ical"
      assert standup["external_id"] == "event1@example.com"
      assert standup["title"] == "Team standup"
      assert standup["occurred_at"] == ~U[2025-03-15 10:00:00Z]
      assert standup["data"]["end_at"] == ~U[2025-03-15 11:00:00Z]
      assert standup["data"]["location"] == "Zoom"
      assert standup["data"]["calendar"] == "Work"
    end

    test "an empty calendar yields no entries" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 200, "BEGIN:VCALENDAR\nEND:VCALENDAR\n")
      end)

      assert {:ok, [], _state} = ICalConnector.sync(state())
    end

    test "a non-200 response fails the sync" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 404, "gone") end)

      assert {:error, "HTTP 404", _state} = ICalConnector.sync(state())
    end

    # The calendar URL comes from the user, so it must never be usable to reach
    # the host's own network (SSRF).
    test "refuses a URL that is not publicly routable" do
      Req.Test.stub(Servant.HTTP, fn _conn -> flunk("the guard should have refused") end)

      for url <- ["http://127.0.0.1/cal.ics", "http://169.254.169.254/", "http://10.0.0.1/cal"] do
        assert {:error, "Refusing to fetch a non-public URL", _state} =
                 ICalConnector.sync(state(%{"url" => url}))
      end
    end

    test "an event without a uid falls back to its summary" do
      ical = """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART:20250315T100000Z
      SUMMARY:Anonymous meeting
      END:VEVENT
      END:VCALENDAR
      """

      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, ical) end)

      assert {:ok, [entry], _state} = ICalConnector.sync(state())
      assert entry["external_id"] == "Anonymous meeting"
    end

    test "an event without a start date still yields an entry" do
      ical =
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u1\nSUMMARY:Whenever\nEND:VEVENT\nEND:VCALENDAR\n"

      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, ical) end)

      assert {:ok, [entry], _state} = ICalConnector.sync(state())
      assert %DateTime{} = entry["occurred_at"]
      assert entry["data"]["end_at"] == nil
    end
  end

  describe "import_ical/2" do
    test "parses an uploaded file with the same shape as a sync" do
      {:ok, state} = ICalConnector.init(%{}, %{"calendar_name" => "Imported"})

      assert {:ok, entries} = ICalConnector.import_ical(@sample_ical, state)
      assert length(entries) == 3
      assert hd(entries)["data"]["calendar"] == "Imported"
    end
  end
end
