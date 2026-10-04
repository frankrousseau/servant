defmodule Servant.CardDAV do
  @moduledoc """
  Data access for the CardDAV endpoint.

  There is one "contacts" address book. It contains only the contacts that
  the user wrote (source "manual" or "carddav"). The module deliberately
  excludes the contacts of a vCard feed (source "vcard", a URL that a schedule
  polls), because the next sync cancels each edit from a phone. A vCard file
  that the user imports manually is not a feed. It becomes a "manual" contact,
  so it does go to the phone (see `Servant.Connectors.VCardConnector`).
  """

  alias Servant.CardDAV.VCard
  alias Servant.Data

  @exposed_sources ~w(manual carddav)

  @doc "Returns the contacts of the address book."
  def contacts(user_id) do
    user_id
    |> Data.all_entries(%{"kind" => "contact"})
    |> Enum.filter(&(&1.source in @exposed_sources))
  end

  @doc "Returns the contact with this resource filename, or nil."
  def get_contact(user_id, filename) do
    Enum.find(contacts(user_id), &(resource_name(&1) == filename))
  end

  @doc "Returns the resource filename of a contact. The client sets it for phone-created contacts."
  def resource_name(entry), do: entry.data["carddav_filename"] || "#{entry.id}.vcf"

  @doc """
  Returns the display name of each contact of the user, by entry id. A
  relation points at an entry id, but a vCard points at a person. As a result,
  the names of the other contacts are necessary to render the RELATED lines of
  one contact. The result includes the connector-synced contacts, although
  the module does not expose them as resources: a relation can point at one.
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

  # Search by resource name first, then by UID in all the exposed contacts. A
  # client can push again a card that it fetched. An imported card keeps its
  # initial UID, and an app-made card has `<id>@servant`. Such a push must
  # update the card and must not make a duplicate.
  defp resolve_target(user_id, filename, uid) do
    contacts = contacts(user_id)

    Enum.find(contacts, &(resource_name(&1) == filename)) ||
      (uid && Enum.find(contacts, &(VCard.uid(&1) == uid)))
  end

  def delete_contact(user_id, entry), do: Data.delete_entry(user_id, entry.id)
end
