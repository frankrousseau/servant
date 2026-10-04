defmodule Servant.Connectors.ICalConnector do
  @moduledoc """
  Connector that fetches events from an iCal (.ics) feed URL
  and creates calendar event entries.
  """

  use Servant.Connectors.Connector

  @impl true
  def id, do: "ical"

  @impl true
  def name, do: "iCal Calendar"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "event"

  @impl true
  def default_schedule, do: "every_hour"

  @impl true
  def init(_credentials, config) do
    url = config_value(config, "url")
    calendar_name = Map.get(config, "calendar_name", "Calendar")

    # The URL is optional. The connector can work with file uploads only.
    {:ok, %{url: url, calendar_name: calendar_name}}
  end

  @impl true
  def sync(%{url: nil} = state) do
    # No URL configured: import-only mode
    {:ok, [], state}
  end

  def sync(%{url: url} = state) do
    case fetch_ical(url) do
      {:ok, body} ->
        entries = build_entries(body, state)
        {:ok, entries, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Parses iCal content and returns entry maps that are ready for the insert.
  The upload endpoint calls this function for file imports.
  """
  def import_ical(ical_content, state) do
    entries = build_entries(ical_content, state)
    {:ok, entries}
  end

  defp build_entries(body, state) do
    events = parse_ical(body)

    Enum.map(events, fn event ->
      title = event[:summary] || "Untitled event"
      dtstart = event[:dtstart]
      dtend = event[:dtend]
      uid = event[:uid] || title

      occurred_at =
        case parse_ical_datetime(dtstart) do
          {:ok, dt} -> dt
          _ -> DateTime.truncate(DateTime.utc_now(), :second)
        end

      end_at =
        case parse_ical_datetime(dtend) do
          {:ok, dt} -> dt
          _ -> nil
        end

      %{
        "kind" => "event",
        "source" => "ical",
        "external_id" => uid,
        "title" => title,
        "occurred_at" => occurred_at,
        "data" => %{
          "summary" => event[:summary],
          "description" => event[:description],
          "location" => event[:location],
          "dtstart" => dtstart,
          "dtend" => dtend,
          "end_at" => end_at,
          "url" => event[:url],
          "calendar" => state.calendar_name
        },
        "metadata" => %{}
      }
    end)
  end

  defp fetch_ical(url) do
    with :ok <- Servant.HTTP.ensure_public_url(url),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, Servant.HTTP.req_options(verify: false)) do
      {:ok, body}
    else
      {:error, :blocked_url} -> {:error, "Refusing to fetch a non-public URL"}
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def parse_ical(body) do
    body
    |> unfold_lines()
    |> extract_vevents()
    |> Enum.map(&parse_vevent/1)
  end

  # iCal spec: the lines that start with a space or a tab are continuations.
  defp unfold_lines(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/)
  end

  defp extract_vevents(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {events, current} ->
      cond do
        String.starts_with?(line, "BEGIN:VEVENT") ->
          {events, []}

        String.starts_with?(line, "END:VEVENT") and is_list(current) ->
          {[Enum.reverse(current) | events], nil}

        is_list(current) ->
          {events, [line | current]}

        true ->
          {events, current}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_vevent(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case parse_property(line) do
        {"SUMMARY", value} -> Map.put(acc, :summary, value)
        {"DESCRIPTION", value} -> Map.put(acc, :description, unescape(value))
        {"LOCATION", value} -> Map.put(acc, :location, value)
        {"DTSTART" <> _, value} -> Map.put(acc, :dtstart, value)
        {"DTEND" <> _, value} -> Map.put(acc, :dtend, value)
        {"UID", value} -> Map.put(acc, :uid, value)
        {"URL", value} -> Map.put(acc, :url, value)
        _ -> acc
      end
    end)
  end

  defp parse_property(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> {String.upcase(key), String.trim(value)}
      _ -> {nil, nil}
    end
  end

  defp unescape(text) do
    text
    |> String.replace("\\n", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  @doc false
  def parse_ical_datetime(nil), do: {:error, nil}

  def parse_ical_datetime(str) do
    str = String.trim(str)

    cond do
      # 20250315T120000Z
      Regex.match?(~r/^\d{8}T\d{6}Z$/, str) ->
        <<y::binary-4, m::binary-2, d::binary-2, ?T, h::binary-2, mi::binary-2, s::binary-2, ?Z>> =
          str

        build_datetime(y, m, d, h, mi, s)

      # 20250315T120000 (no timezone, treat as UTC)
      Regex.match?(~r/^\d{8}T\d{6}$/, str) ->
        parse_ical_datetime(str <> "Z")

      # 20250315 (date only)
      Regex.match?(~r/^\d{8}$/, str) ->
        <<y::binary-4, m::binary-2, d::binary-2>> = str

        build_datetime(y, m, d, "00", "00", "00")

      true ->
        {:error, :invalid_format}
    end
  end

  # Uses Date.new/Time.new, which do not raise. The regexes above validate only
  # the digit *shape*, not the values. Some broken calendar generators emit a
  # well-formed but invalid stamp (Feb 30, hour 24). Such a stamp must return
  # {:error, _}. It must not raise and crash the worker on a single bad VEVENT.
  defp build_datetime(y, m, d, h, mi, s) do
    with {:ok, date} <- Date.new(int(y), int(m), int(d)),
         {:ok, time} <- Time.new(int(h), int(mi), int(s)) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp int(bin), do: String.to_integer(bin)
end
