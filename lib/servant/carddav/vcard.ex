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

  `:names` maps contact ids to display names (see `Servant.CardDAV.contact_names/1`)
  and is what turns stored relations into RELATED lines; without it the
  synthesized card simply carries none.
  """
  def to_vcf(entry, opts \\ []) do
    fresh_raw(entry) || synthesize(entry, Keyword.get(opts, :names, %{}))
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

  @doc """
  UID exposed over CardDAV: the one inherited from a merged duplicate
  (`carddav_uid`, see `Servant.Contacts.merge/3`), else the client-supplied
  one, else a stable Servant-made value.
  """
  def uid(entry), do: entry.data["carddav_uid"] || entry.external_id || "#{entry.id}@servant"

  defp synthesize(entry, names) do
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
        categories_line(d["tags"]) ++
        related_lines(d["relations"], names) ++
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

  # Tags become CATEGORIES, the property clients surface as groups. The value
  # is a comma-separated list, and escape/1 already escapes a comma inside a
  # tag, so joining after escaping is safe.
  defp categories_line(tags) when is_list(tags) do
    case Enum.filter(tags, &(is_binary(&1) and &1 != "")) do
      [] -> []
      list -> ["CATEGORIES:" <> Enum.map_join(list, ",", &escape/1)]
    end
  end

  defp categories_line(_tags), do: []

  # Relations point at entry ids while a vCard points at people, so RELATED
  # carries the target's name as text: the one form every client renders, and
  # the only one that still works when the target is not exposed as a resource
  # (connector-synced contacts). A target we can't name is skipped.
  defp related_lines(relations, names) when is_list(relations) do
    Enum.flat_map(relations, fn
      %{"contact_id" => id, "type" => type} when is_binary(id) and is_binary(type) ->
        case Map.get(names, id) do
          nil -> []
          name -> ["RELATED;TYPE=#{type_param(type)};VALUE=text:#{escape(name)}"]
        end

      _ ->
        []
    end)
  end

  defp related_lines(_relations, _names), do: []

  # A custom relation type can hold spaces, which a bare param value can't.
  defp type_param(type) do
    if String.match?(type, ~r/\A[A-Za-z0-9-]+\z/) do
      String.upcase(type)
    else
      ~s("#{String.replace(type, ~s("), "")}")
    end
  end

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end
end
