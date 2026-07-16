defmodule Servant.CardDAV do
  @moduledoc """
  Data access for the CardDAV endpoint: a single "contacts" address book
  containing user-authored contacts only (source "manual" or "carddav").
  Connector-synced contacts (vcard imports) are deliberately excluded: they
  are re-fetched on a schedule and don't preserve a phone's raw vCard payload,
  so exposing them for editing over DAV would drop that payload on the next sync.
  """

  alias Servant.CardDAV.VCard
  alias Servant.Data

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

  defp resolve_target(user_id, filename, uid) do
    contacts = contacts(user_id)

    Enum.find(contacts, &(resource_name(&1) == filename)) ||
      (uid && Enum.find(contacts, &(&1.source == "carddav" and &1.external_id == uid)))
  end

  def delete_contact(user_id, entry), do: Data.delete_entry(user_id, entry.id)
end
