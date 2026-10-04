defmodule Servant.CalDAV do
  @moduledoc """
  Data access for the CalDAV endpoint.

  There is one collection for each calendar: the "agenda" entities of kind
  "calendar" and the "Manual" calendar, which is always there. A collection
  contains only the events that the user wrote (source "manual" or "caldav").
  The module deliberately excludes the events that a connector syncs (ical,
  ...). A schedule fetches these events again, and they do not keep the raw
  ICS payload of a phone. If DAV exposes them for edits, the next sync drops
  that payload. Subscribe to those feeds directly on the phone.
  """

  alias Servant.CalDAV.ICS
  alias Servant.Data

  @exposed_sources ~w(manual caldav)

  @doc "Returns the names of the calendar collections for a user."
  def calendars(user_id) do
    entity_names =
      user_id
      |> Data.all_entries(%{"kind" => "calendar"})
      |> Enum.map(&String.trim(&1.title || ""))

    # An agenda can also exist only as a reference in events (the app builds
    # its agenda list the same way). Without these names, DAV clients cannot
    # see a user-authored event in an agenda that has no entity.
    event_names = Enum.map(exposed_events(user_id), &calendar_of/1)

    Enum.uniq(["Manual" | Enum.reject(entity_names ++ event_names, &(&1 == ""))])
  end

  @doc "Returns the events of one calendar collection."
  def events(user_id, cal_name) do
    Enum.filter(exposed_events(user_id), &(calendar_of(&1) == cal_name))
  end

  defp exposed_events(user_id) do
    user_id
    |> Data.all_entries(%{"kind" => "event"})
    |> Enum.filter(&(&1.source in @exposed_sources))
  end

  defp calendar_of(entry) do
    case String.trim(entry.data["calendar"] || "") do
      "" -> "Manual"
      name -> name
    end
  end

  @doc "Returns the event of a collection with this resource filename, or nil."
  def get_event(user_id, cal_name, filename) do
    Enum.find(events(user_id, cal_name), &(resource_name(&1) == filename))
  end

  @doc "Returns the resource filename of an event. The client sets it for phone-created events."
  def resource_name(entry), do: entry.data["caldav_filename"] || "#{entry.id}.ics"

  @doc """
  Creates or updates an event from an ICS payload. A filename or a UID that
  matches outside `cal_name` is a move into this collection: CalDAV clients
  PUT the new copy before they delete the old copy.
  Returns `{:ok, entry, :created | :updated}` or `{:error, reason}`.
  """
  def put_event(user_id, cal_name, filename, ics_body, user_tz) do
    with {:ok, parsed} <- ICS.parse_event(ics_body, user_tz) do
      caldav_data = %{
        "calendar" => cal_name,
        "caldav_filename" => filename,
        "caldav_ics" => ics_body,
        "caldav_ics_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      case resolve_target(user_id, filename, parsed.uid) do
        nil ->
          attrs = %{
            "kind" => "event",
            "source" => "caldav",
            "external_id" => parsed.uid,
            "title" => parsed.title,
            "occurred_at" => parsed.occurred_at,
            "data" => Map.merge(parsed.data, caldav_data)
          }

          with {:ok, entry} <- Data.create_entry(user_id, attrs), do: {:ok, entry, :created}

        entry ->
          attrs = %{
            "title" => parsed.title,
            "occurred_at" => parsed.occurred_at,
            "data" => entry.data |> Map.merge(parsed.data) |> Map.merge(caldav_data)
          }

          with {:ok, entry} <- Data.update_entry(user_id, entry.id, attrs),
               do: {:ok, entry, :updated}
      end
    end
  end

  defp resolve_target(user_id, filename, uid) do
    events = exposed_events(user_id)

    Enum.find(events, &(resource_name(&1) == filename)) ||
      (uid && Enum.find(events, &(&1.source == "caldav" and &1.external_id == uid)))
  end

  def delete_event(user_id, entry), do: Data.delete_entry(user_id, entry.id)
end
