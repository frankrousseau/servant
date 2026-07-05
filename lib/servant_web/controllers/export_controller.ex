defmodule ServantWeb.ExportController do
  @moduledoc "Entry exports: full JSON dump and iCal calendar."

  use ServantWeb, :controller

  def entries(conn, _params) do
    user_id = conn.assigns.current_user.id
    entries = Servant.Data.all_entries(user_id)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    data = Enum.map(entries, &Servant.Data.Entry.to_json/1)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="servant_entries_#{timestamp}.json")
    )
    |> json(data)
  end

  def ical(conn, _params) do
    user_id = conn.assigns.current_user.id
    events = Servant.Data.all_entries(user_id, %{"kind" => "event"})
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")

    ics = build_ical(events)

    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="servant_calendar_#{timestamp}.ics")
    )
    |> send_resp(200, ics)
  end

  defp build_ical(events) do
    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Servant//Calendar Export//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH"
    ]

    event_lines = Enum.flat_map(events, &build_vevent/1)

    Enum.join(lines ++ event_lines ++ ["END:VCALENDAR"], "\r\n")
  end

  defp build_vevent(entry) do
    uid = entry.external_id || entry.id
    summary = ical_escape(entry.title || "Untitled")
    dtstart = format_ical_dt(entry.data["dtstart"] || entry.occurred_at)
    dtend = format_ical_dt(entry.data["dtend"])

    lines = [
      "BEGIN:VEVENT",
      "UID:#{uid}",
      "SUMMARY:#{summary}",
      "DTSTART:#{dtstart}"
    ]

    lines = if dtend, do: lines ++ ["DTEND:#{dtend}"], else: lines

    lines =
      if entry.data["location"] do
        lines ++ ["LOCATION:#{ical_escape(entry.data["location"])}"]
      else
        lines
      end

    lines =
      if entry.data["description"] do
        lines ++ ["DESCRIPTION:#{ical_escape(entry.data["description"])}"]
      else
        lines
      end

    lines ++ ["END:VEVENT"]
  end

  defp format_ical_dt(nil), do: nil

  defp format_ical_dt(val) when is_binary(val) do
    # Already in iCal format (e.g. "20250315T100000Z")
    if Regex.match?(~r/^\d{8}T?\d{0,6}Z?$/, val) do
      val
    else
      # Try ISO8601
      case DateTime.from_iso8601(val) do
        {:ok, dt, _} -> Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
        _ -> nil
      end
    end
  end

  defp format_ical_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")
  end

  defp format_ical_dt(_), do: nil

  defp ical_escape(nil), do: ""

  defp ical_escape(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp ical_escape(val), do: to_string(val)
end
