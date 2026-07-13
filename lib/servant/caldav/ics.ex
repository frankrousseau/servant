defmodule Servant.CalDAV.ICS do
  @moduledoc """
  Minimal iCalendar (RFC 5545) parsing and generation for the CalDAV
  endpoint. Parses only the fields the Calendar app understands; the raw
  payload a client PUT is stored alongside so alarms, attendees and
  complex RRULEs survive round-trips untouched.
  """

  @doc """
  Parses the first VEVENT of an ICS payload into calendar-app entry
  attributes. `user_tz` anchors floating and all-day times, mirroring how
  the app stores wall-clock values in the user's timezone.

  Returns `{:ok, %{uid:, title:, occurred_at:, data: %{...}}}` or
  `{:error, reason}`.
  """
  def parse_event(ics, user_tz) when is_binary(ics) do
    case first_vevent(unfold(ics)) do
      nil ->
        {:error, "No VEVENT found"}

      props ->
        build_parsed(props, user_tz)
    end
  end

  defp build_parsed(props, user_tz) do
    with {:ok, start} <- resolve_dt(props["DTSTART"], user_tz) do
      all_day = match?({:date, _}, start)
      dtend = resolve_optional_dt(props["DTEND"], user_tz)
      summary = text_value(props, "SUMMARY")

      data =
        %{
          "summary" => summary,
          "description" => text_value(props, "DESCRIPTION"),
          "location" => text_value(props, "LOCATION"),
          "all_day" => all_day,
          "recurrence" => simple_recurrence(props["RRULE"]),
          "dtstart" => wall_clock(start, user_tz),
          "dtend" => wall_dtend(start, dtend, user_tz),
          "end_at" => end_at(start, dtend, user_tz)
        }

      {:ok,
       %{
         uid: prop_value(props, "UID"),
         title: summary || "Untitled event",
         occurred_at: start_utc(start, user_tz),
         data: data
       }}
    end
  end

  # iCal spec: lines starting with space/tab continue the previous one.
  defp unfold(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/)
  end

  defp first_vevent(lines) do
    lines
    |> Enum.drop_while(&(!String.starts_with?(&1, "BEGIN:VEVENT")))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.starts_with?(&1, "END:VEVENT")))
    |> case do
      [] -> nil
      body -> Map.new(Enum.reverse(Enum.map(body, &parse_prop/1)))
    end
  end

  # "DTSTART;TZID=Europe/Paris:20260713T100000" -> {"DTSTART", {params, value}}
  defp parse_prop(line) do
    case String.split(line, ":", parts: 2) do
      [head, value] ->
        [name | params] = String.split(head, ";")

        params =
          Map.new(params, fn p ->
            case String.split(p, "=", parts: 2) do
              [k, v] -> {String.upcase(k), String.trim(v, "\"")}
              [k] -> {String.upcase(k), ""}
            end
          end)

        {String.upcase(name), {params, String.trim(value)}}

      _ ->
        {line, {%{}, ""}}
    end
  end

  defp prop_value(props, name) do
    case props[name] do
      {_params, ""} -> nil
      {_params, value} -> value
      nil -> nil
    end
  end

  defp text_value(props, name) do
    case prop_value(props, name) do
      nil -> nil
      value -> unescape(value)
    end
  end

  defp unescape(text) do
    text
    |> String.replace("\\\\", "\0")
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\0", "\\")
  end

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  # --- datetimes ---
  # Resolved values are {:date, %Date{}} (all-day) or {:utc, %DateTime{}}.

  defp resolve_dt(nil, _tz), do: {:error, "Missing DTSTART"}

  defp resolve_dt({params, value}, user_tz) do
    cond do
      params["VALUE"] == "DATE" or Regex.match?(~r/^\d{8}$/, value) ->
        with {:ok, date} <- parse_date(value), do: {:ok, {:date, date}}

      Regex.match?(~r/^\d{8}T\d{6}Z$/, value) ->
        with {:ok, naive} <- parse_naive(binary_part(value, 0, 15)),
             {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, {:utc, dt}}
        end

      Regex.match?(~r/^\d{8}T\d{6}$/, value) ->
        tz = params["TZID"] || user_tz

        with {:ok, naive} <- parse_naive(value),
             {:ok, dt} <- from_naive_in_zone(naive, tz) do
          {:ok, {:utc, DateTime.shift_zone!(dt, "Etc/UTC")}}
        end

      true ->
        {:error, "Unsupported datetime: #{value}"}
    end
  end

  defp resolve_optional_dt(nil, _tz), do: nil

  defp resolve_optional_dt(prop, user_tz) do
    case resolve_dt(prop, user_tz) do
      {:ok, resolved} -> resolved
      _ -> nil
    end
  end

  defp parse_date(<<y::binary-4, m::binary-2, d::binary-2>>) do
    Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d))
  end

  defp parse_date(_), do: {:error, "Invalid date"}

  defp parse_naive(
         <<y::binary-4, mo::binary-2, d::binary-2, ?T, h::binary-2, mi::binary-2, s::binary-2>>
       ) do
    NaiveDateTime.new(
      String.to_integer(y),
      String.to_integer(mo),
      String.to_integer(d),
      String.to_integer(h),
      String.to_integer(mi),
      String.to_integer(s)
    )
  end

  # DST gaps/ambiguities: take the earliest valid wall clock, sync must not fail.
  defp from_naive_in_zone(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_dt} -> {:ok, after_dt}
      {:error, _} -> {:error, "Unknown timezone: #{tz}"}
    end
  end

  defp start_utc({:date, date}, user_tz) do
    date |> zoned(~T[00:00:00], user_tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp start_utc({:utc, dt}, _tz), do: dt

  # The app stores dtstart/dtend as wall-clock in the user's timezone
  # ("20260713T100000") and date-only for all-day events ("20260713").
  defp wall_clock({:date, date}, _tz), do: Calendar.strftime(date, "%Y%m%d")

  defp wall_clock({:utc, dt}, user_tz) do
    dt |> DateTime.shift_zone!(user_tz) |> Calendar.strftime("%Y%m%dT%H%M%S")
  end

  # iCal all-day DTEND is exclusive; the app stores the inclusive end date.
  defp wall_dtend({:date, _}, {:date, end_date}, _tz) do
    Calendar.strftime(Date.add(end_date, -1), "%Y%m%d")
  end

  defp wall_dtend({:date, start_date}, _end, _tz), do: Calendar.strftime(start_date, "%Y%m%d")
  defp wall_dtend(_start, {:utc, dt}, user_tz), do: wall_clock({:utc, dt}, user_tz)
  defp wall_dtend(_start, _end, _tz), do: nil

  defp end_at({:date, start_date}, dtend, user_tz) do
    end_date =
      case dtend do
        {:date, date} -> Date.add(date, -1)
        _ -> start_date
      end

    end_date
    |> latest(start_date)
    |> zoned(~T[23:59:00], user_tz)
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp end_at(_start, {:utc, dt}, _tz), do: DateTime.to_iso8601(dt)
  defp end_at(_start, _end, _tz), do: nil

  defp latest(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp zoned(date, time, tz) do
    case DateTime.new(date, time, tz) do
      {:ok, dt} -> dt
      {:ambiguous, first, _} -> first
      {:gap, _, after_dt} -> after_dt
      {:error, _} -> DateTime.new!(date, time, "Etc/UTC")
    end
  end

  # Only bare FREQ rules map onto the app's simple recurrence field; anything
  # richer stays in the stored raw ICS.
  defp simple_recurrence(nil), do: nil

  defp simple_recurrence({_params, value}) do
    parts =
      Map.new(String.split(value, ";"), fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {String.upcase(k), String.upcase(v)}
          [k] -> {String.upcase(k), ""}
        end
      end)

    freq = parts["FREQ"]
    simple? = Map.keys(parts) -- ["FREQ", "INTERVAL"] == [] and parts["INTERVAL"] in [nil, "1"]

    if simple? and freq in ~w(WEEKLY MONTHLY YEARLY) do
      String.downcase(freq)
    end
  end

  # --- generation ---

  @doc """
  Renders an event entry as a VCALENDAR. Returns the raw ICS a client
  stored if the entry was not touched since (lossless round-trip),
  otherwise synthesizes a VEVENT from the entry fields.
  """
  def to_ics(entry, user_tz) do
    fresh_raw(entry) || synthesize(entry, user_tz)
  end

  defp fresh_raw(entry) do
    with raw when is_binary(raw) <- entry.data["caldav_ics"],
         {:ok, ics_at, _} <- DateTime.from_iso8601(entry.data["caldav_ics_at"] || "") do
      # 2s slack: the PUT stamps ics_at and updated_at in the same write.
      if DateTime.compare(ics_at, DateTime.add(entry.updated_at, -2)) != :lt, do: raw
    else
      _ -> nil
    end
  end

  @doc "UID exposed over CalDAV; client-supplied when available."
  def uid(entry), do: entry.external_id || "#{entry.id}@servant"

  defp synthesize(entry, user_tz) do
    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Servant//CalDAV//EN",
        "BEGIN:VEVENT",
        "UID:#{uid(entry)}",
        "DTSTAMP:#{Calendar.strftime(entry.updated_at, "%Y%m%dT%H%M%SZ")}",
        "SUMMARY:#{escape(entry.title || "Untitled")}"
      ] ++
        dt_lines(entry, user_tz) ++
        optional_line("LOCATION", entry.data["location"]) ++
        optional_line("DESCRIPTION", entry.data["description"]) ++
        rrule_line(entry.data["recurrence"]) ++
        ["END:VEVENT", "END:VCALENDAR", ""]

    Enum.join(lines, "\r\n")
  end

  defp dt_lines(entry, user_tz) do
    if entry.data["all_day"] do
      start_date = date_from_wall(entry.data["dtstart"]) || DateTime.to_date(entry.occurred_at)
      end_date = date_from_wall(entry.data["dtend"]) || start_date
      exclusive_end = Date.add(latest(end_date, start_date), 1)

      [
        "DTSTART;VALUE=DATE:#{Calendar.strftime(start_date, "%Y%m%d")}",
        "DTEND;VALUE=DATE:#{Calendar.strftime(exclusive_end, "%Y%m%d")}"
      ]
    else
      start_line = ["DTSTART:#{Calendar.strftime(entry.occurred_at, "%Y%m%dT%H%M%SZ")}"]

      case end_utc(entry.data["end_at"], user_tz) do
        nil -> start_line
        dt -> start_line ++ ["DTEND:#{Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")}"]
      end
    end
  end

  defp date_from_wall(<<y::binary-4, m::binary-2, d::binary-2>> <> _) do
    case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date_from_wall(_), do: nil

  defp end_utc(nil, _tz), do: nil

  defp end_utc(iso, _tz) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> nil
    end
  end

  defp optional_line(_name, nil), do: []
  defp optional_line(_name, ""), do: []
  defp optional_line(name, value), do: ["#{name}:#{escape(to_string(value))}"]

  defp rrule_line(rec) when rec in ~w(weekly monthly yearly),
    do: ["RRULE:FREQ=#{String.upcase(rec)}"]

  defp rrule_line(_), do: []
end
