defmodule Servant.CalDAV do
  @moduledoc """
  Data access for the CalDAV endpoint: one collection per calendar
  ("agenda" entities of kind "calendar" plus the ever-present "Manual"),
  containing user-authored events only (source "manual" or "caldav").
  Connector-synced events (ical, ...) are deliberately excluded: their
  syncs wholesale-replace entries, so phone edits would be lost.
  """

  alias Servant.CalDAV.ICS
  alias Servant.Data

  @exposed_sources ~w(manual caldav)

  @doc "Calendar collection names for a user."
  def calendars(user_id) do
    names =
      user_id
      |> Data.all_entries(%{"kind" => "calendar"})
      |> Enum.map(&String.trim(&1.title || ""))
      |> Enum.reject(&(&1 == ""))

    Enum.uniq(["Manual" | names])
  end

  @doc "Events of one calendar collection."
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

  @doc "Event of a collection by its resource filename, or nil."
  def get_event(user_id, cal_name, filename) do
    Enum.find(events(user_id, cal_name), &(resource_name(&1) == filename))
  end

  @doc "Resource filename of an event: client-chosen for phone-created events."
  def resource_name(entry), do: entry.data["caldav_filename"] || "#{entry.id}.ics"

  @doc """
  Creates or updates an event from an ICS payload. A filename or UID match
  outside `cal_name` is treated as a move into this collection (CalDAV
  clients PUT the new copy before deleting the old one).
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
