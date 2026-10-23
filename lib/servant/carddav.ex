defmodule Servant.CardDAV do
  @moduledoc """
  Data access for the CardDAV endpoint: a single "contacts" address book
  containing user-authored contacts only (source "manual" or "carddav").
  Contacts of a vCard feed (source "vcard", a URL polled on a schedule) are
  deliberately excluded: the next sync would undo whatever a phone edited.
  A vCard file imported by hand is not a feed and lands as a "manual" contact,
  so it does reach the phone (see `Servant.Connectors.VCardConnector`).
  """

  import Ecto.Query
  alias Servant.CardDAV.VCard
  alias Servant.Data
  alias Servant.Data.Entry
  alias Servant.Repo

  @exposed_sources ~w(manual carddav)

  @doc "Contacts of the address book."
  def contacts(user_id) do
    user_id
    |> Data.all_entries(%{"kind" => "contact"})
    |> Enum.filter(&(&1.source in @exposed_sources))
  end

  @doc "Contact by its resource filename, or nil."
  def get_contact(user_id, filename) do
    Enum.find(contacts(user_id), &(resource_name(&1) == filename))
  end

  @doc "Resource filename of a contact: client-chosen for phone-created ones."
  def resource_name(entry), do: entry.data["carddav_filename"] || "#{entry.id}.vcf"

  @doc """
  Display name of every contact of the user, by entry id. Relations point at
  entry ids while a vCard points at people, so rendering one contact's RELATED
  lines needs the others' names. Connector-synced contacts are included even
  though they are not exposed as resources: a relation may well point at one.
  """
  def contact_names(user_id) do
    user_id
    |> Data.all_entries(%{"kind" => "contact"})
    |> Map.new(&{&1.id, &1.data["display_name"] || &1.title || "Unnamed"})
  end

  @doc """
  Creates or updates a contact from a vCard payload.
  Returns `{:ok, entry, :created | :updated}` or `{:error, reason}`.
  """
  def put_contact(user_id, filename, vcf_body) do
    with {:ok, parsed} <- VCard.parse_contact(vcf_body) do
      carddav_data = %{
        "carddav_filename" => filename,
        "carddav_vcf" => vcf_body,
        "carddav_vcf_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      case resolve_target(user_id, filename, parsed.uid) do
        nil ->
          attrs = %{
            "kind" => "contact",
            "source" => "carddav",
            "external_id" => parsed.uid,
            "title" => parsed.title,
            "occurred_at" => parsed.birthday_at || DateTime.utc_now(),
            "data" => Map.merge(parsed.data, carddav_data)
          }

          with {:ok, entry} <- Data.create_entry(user_id, attrs), do: {:ok, entry, :created}

        entry ->
          attrs = %{
            "title" => parsed.title,
            "occurred_at" => parsed.birthday_at || entry.occurred_at,
            "data" => entry.data |> Map.merge(parsed.data) |> Map.merge(carddav_data)
          }

          with {:ok, entry} <- Data.update_entry(user_id, entry.id, attrs),
               do: {:ok, entry, :updated}
      end
    end
  end

  # By resource name first, then by UID over every exposed contact: a client
  # re-pushing a card it fetched (an imported one keeps its original UID, an
  # app-made one carries `<id>@servant`) must update it, not duplicate it.
  defp resolve_target(user_id, filename, uid) do
    contacts = contacts(user_id)

    Enum.find(contacts, &(resource_name(&1) == filename)) ||
      (uid && Enum.find(contacts, &(VCard.uid(&1) == uid)))
  end

  def delete_contact(user_id, entry), do: Data.delete_entry(user_id, entry.id)

  @doc """
  Parses the stored raw vCard of each exposed contact again and fixes the
  entry fields that differ. For cards stored before a parser fix (grouped
  `item1.TEL` and lowercase `type=` params were dropped). Only a raw card
  that is still fresh is the truth; a contact edited in Servant since is
  left alone. Returns `{updated, scanned}`.
  """
  def backfill_parsed_fields(user_id \\ nil) do
    contacts =
      from(entry in Entry,
        where: entry.kind == "contact",
        where: entry.source in @exposed_sources,
        where: fragment("json_extract(?, '$.carddav_vcf') IS NOT NULL", entry.data)
      )
      |> then(fn query -> if user_id, do: where(query, user_id: ^user_id), else: query end)
      |> Repo.all()

    updated = Enum.count(contacts, &backfill_contact/1)
    {updated, length(contacts)}
  end

  defp backfill_contact(entry) do
    with raw when is_binary(raw) <- VCard.fresh_raw(entry),
         {:ok, parsed} <- VCard.parse_contact(raw),
         true <- Enum.any?(parsed.data, fn {key, value} -> entry.data[key] != value end),
         {:ok, _entry} <-
           entry
           |> Entry.changeset(%{
             title: parsed.title,
             # Re-stamped so the raw card stays the one served to the phone.
             data:
               entry.data
               |> Map.merge(parsed.data)
               |> Map.put("carddav_vcf_at", DateTime.to_iso8601(DateTime.utc_now()))
           })
           |> Repo.update() do
      true
    else
      _ -> false
    end
  end
end
