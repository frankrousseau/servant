defmodule Servant.CardDAV.VCard do
  @moduledoc """
  vCard parsing and generation for the CardDAV endpoint. Parsing reuses
  the vCard connector's parser; only the fields the Contacts app
  understands are mapped, and the raw payload a client PUT is stored
  alongside so photos, structured names and unknown fields survive
  round-trips untouched.
  """

  alias Servant.Connectors.VCardConnector

  @doc """
  Parses the first vCard of a payload into contact entry attributes.
  Returns `{:ok, %{uid:, title:, birthday_at:, data: %{...}}}` or
  `{:error, reason}`.
  """
  def parse_contact(vcf) when is_binary(vcf) do
    case VCardConnector.parse_vcards(vcf) do
      [contact | _] ->
        data = %{
          "display_name" => contact.display_name,
          "emails" => contact.emails,
          "phones" => contact.phones,
          "org" => contact.org,
          "title" => contact.title,
          "url" => contact.url,
          "note" => contact.note,
          "birthday" => contact.birthday,
          "address" => clean_address(contact.address)
        }

        {:ok,
         %{
           uid: contact.uid,
           title: entry_title(contact),
           birthday_at: birthday_datetime(contact.birthday),
           data: data
         }}

      [] ->
        {:error, "No vCard found"}
    end
  end

  # Same "Name - org - email" composition as the app and the vCard connector.
  defp entry_title(contact) do
    subtitle =
      [contact.org, contact.title, contact.emails |> Enum.map(& &1["value"]) |> List.first()]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")

    if subtitle == "", do: contact.display_name, else: "#{contact.display_name} - #{subtitle}"
  end

  # The app stores the address as free text; flatten structured ADR values.
  defp clean_address(nil), do: nil

  defp clean_address(adr) do
    adr
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      flat -> flat
    end
  end

  defp birthday_datetime(nil), do: nil

  defp birthday_datetime(str) do
    date =
      case String.trim(str) do
        <<y::binary-4, ?-, m::binary-2, ?-, d::binary-2>> -> Date.from_iso8601("#{y}-#{m}-#{d}")
        <<y::binary-4, m::binary-2, d::binary-2>> -> Date.from_iso8601("#{y}-#{m}-#{d}")
        _ -> :error
      end

    case date do
      {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  # --- generation ---

  @doc """
  Renders a contact entry as a vCard 3.0. Returns the raw vCard a client
  stored if the entry was not touched since, otherwise synthesizes one
  from the entry fields.
  """
  def to_vcf(entry) do
    fresh_raw(entry) || synthesize(entry)
  end

  defp fresh_raw(entry) do
    with raw when is_binary(raw) <- entry.data["carddav_vcf"],
         {:ok, vcf_at, _} <- DateTime.from_iso8601(entry.data["carddav_vcf_at"] || "") do
      # 2s slack: the PUT stamps vcf_at and updated_at in the same write.
      if DateTime.compare(vcf_at, DateTime.add(entry.updated_at, -2)) != :lt, do: raw
    else
      _ -> nil
    end
  end

  @doc "UID exposed over CardDAV; client-supplied when available."
  def uid(entry), do: entry.external_id || "#{entry.id}@servant"

  defp synthesize(entry) do
    d = entry.data
    name = d["display_name"] || entry.title || "Unnamed"

    lines =
      [
        "BEGIN:VCARD",
        "VERSION:3.0",
        "UID:#{uid(entry)}",
        "FN:#{escape(name)}",
        "N:#{escape(name)};;;;",
        "REV:#{Calendar.strftime(entry.updated_at, "%Y%m%dT%H%M%SZ")}"
      ] ++
        typed_lines("EMAIL", d["emails"]) ++
        typed_lines("TEL", d["phones"]) ++
        optional_line("ORG", d["org"]) ++
        optional_line("TITLE", d["title"]) ++
        optional_line("URL", d["url"]) ++
        optional_line("NOTE", d["note"]) ++
        optional_line("BDAY", d["birthday"]) ++
        address_line(d["address"]) ++
        ["END:VCARD", ""]

    Enum.join(lines, "\r\n")
  end

  defp typed_lines(prop, values) when is_list(values) do
    Enum.flat_map(values, fn
      %{"value" => value} = v when is_binary(value) and value != "" ->
        case v["type"] do
          type when type in [nil, "", "other"] -> ["#{prop}:#{escape(value)}"]
          type -> ["#{prop};TYPE=#{String.upcase(type)}:#{escape(value)}"]
        end

      _ ->
        []
    end)
  end

  defp typed_lines(_prop, _), do: []

  defp optional_line(_name, value) when value in [nil, ""], do: []
  defp optional_line(name, value), do: ["#{name}:#{escape(to_string(value))}"]

  defp address_line(value) when value in [nil, ""], do: []
  defp address_line(value), do: ["ADR;TYPE=HOME:;;#{escape(value)};;;;"]

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end
end
