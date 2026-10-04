defmodule Servant.Connectors.VCardConnector do
  @moduledoc """
  Connector that imports contacts from a vCard (.vcf) file or URL.
  Supports the vCard 3.0 and 4.0 formats.
  """

  use Servant.Connectors.Connector

  alias Servant.HTTP
  alias Servant.Storage

  # In practice, contact photos have the size of a portrait. Above this limit, a
  # card contains something else. Leave it in the raw payload and do not store it.
  @max_photo_bytes 10_000_000

  @impl true
  def id, do: "vcard"

  @impl true
  def name, do: "Contacts (vCard)"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "contact"

  @impl true
  def default_schedule, do: "on_demand"

  @impl true
  def supported_schedules, do: ~w(on_demand every_day every_week)

  @impl true
  def init(_credentials, config) do
    url = config_value(config, "url")
    source_name = Map.get(config, "source_name", "Contacts")
    {:ok, %{url: url, source_name: source_name}}
  end

  @impl true
  def sync(%{url: nil} = state) do
    {:ok, [], state}
  end

  def sync(%{url: url} = state) do
    case fetch_vcf(url) do
      {:ok, body} ->
        entries = build_entries(body, state)
        {:ok, entries, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Parses vCard content and returns entry maps.
  The file import endpoint calls this function.

  A dropped file is a hand-off of the user's own address book, not a feed. As a
  result, its cards become ordinary "manual" contacts and keep their raw payload.
  CardDAV exposes them like any contact that the user wrote, and they reach the
  phone.
  """
  def import_vcard(vcf_content, state) do
    entries =
      vcf_content
      |> parse_vcards_with_raw()
      |> Enum.map(fn {contact, raw} -> build_entry(contact, state, "manual", raw) end)

    {:ok, entries}
  end

  defp build_entries(body, state) do
    body
    |> parse_vcards()
    |> Enum.map(&build_entry(&1, state, "vcard", nil))
  end

  defp fetch_vcf(url) do
    # SSRF guard on the feed URL that the user supplies, as for RSS and iCal.
    # Without it, a vCard connector can point at internal or metadata addresses.
    with :ok <- HTTP.ensure_public_url(url) do
      case Req.get(url, HTTP.req_options(verify: false)) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          {:ok, body}

        {:ok, %Req.Response{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, "request failed: #{inspect(reason)}"}
      end
    else
      {:error, :blocked_url} -> {:error, "URL is not allowed (private/loopback address)"}
    end
  end

  # --- vCard parser ---

  @doc false
  def parse_vcards(body) do
    body
    |> parse_vcards_with_raw()
    |> Enum.map(fn {contact, _raw} -> contact end)
  end

  @doc """
  Same as `parse_vcards/1`, but pairs each contact with the verbatim text of its
  source card. An import keeps that text. As a result, the photos, the structured
  names and the properties that this parser ignores survive the trip to a CardDAV
  client.
  """
  def parse_vcards_with_raw(body) do
    body
    |> split_cards()
    |> Enum.flat_map(fn {raw, lines} ->
      case parse_vcard(lines) do
        nil -> []
        contact -> [{contact, raw}]
      end
    end)
  end

  # Cut the cards out of the original text, with the folding, before the unfold
  # for the parser. The stored payload must stay byte-for-byte what the file
  # contained. A card without its END line is dropped, as it always was.
  defp split_cards(body) do
    ~r/BEGIN:VCARD.*?END:VCARD/is
    |> Regex.scan(body)
    |> Enum.map(fn [raw] -> {raw <> "\r\n", card_lines(raw)} end)
  end

  defp card_lines(raw) do
    raw
    |> unfold_lines()
    |> Enum.drop(1)
    |> Enum.drop(-1)
  end

  defp unfold_lines(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/)
  end

  defp parse_vcard(lines) do
    props =
      Enum.reduce(lines, %{}, fn line, acc ->
        case parse_property(line) do
          {key, value} -> Map.update(acc, key, [value], &(&1 ++ [value]))
          nil -> acc
        end
      end)

    fn_name = get_first(props, "FN")
    n_parts = get_first(props, "N")

    # Build a display name.
    display_name =
      cond do
        fn_name && fn_name != "" ->
          fn_name

        n_parts ->
          n_parts
          |> String.split(";")
          |> Enum.reject(&(&1 == ""))
          |> Enum.reverse()
          |> Enum.join(" ")

        true ->
          nil
      end

    if display_name do
      %{
        display_name: display_name,
        emails: extract_typed_values(props, "EMAIL"),
        phones: extract_typed_values(props, "TEL"),
        org: get_first(props, "ORG"),
        title: get_first(props, "TITLE"),
        url: get_first(props, "URL"),
        note: get_first(props, "NOTE"),
        birthday: get_first(props, "BDAY"),
        address: get_first(props, "ADR"),
        photo: get_first(props, "PHOTO"),
        uid: get_first(props, "UID") || display_name
      }
    end
  end

  defp parse_property(line) do
    case String.split(line, ":", parts: 2) do
      [key_part, value] ->
        # The key can have params such as "TEL;TYPE=WORK;VALUE=uri".
        key =
          key_part
          |> String.split(";")
          |> List.first()
          |> String.upcase()

        type_param = extract_type_param(key_part)
        {key, {value |> String.trim() |> unescape(), type_param}}

      _ ->
        nil
    end
  end

  defp extract_type_param(key_part) do
    key_part
    |> String.split(";")
    |> Enum.find_value(fn param ->
      case String.split(param, "=", parts: 2) do
        ["TYPE", type] -> String.downcase(type)
        [t] when t in ["WORK", "HOME", "CELL", "VOICE", "FAX", "PREF"] -> String.downcase(t)
        _ -> nil
      end
    end)
  end

  defp get_first(props, key) do
    case Map.get(props, key) do
      [{value, _type} | _] ->
        cleaned = value |> String.trim() |> String.trim(";") |> String.trim()
        if cleaned == "", do: nil, else: cleaned

      _ ->
        nil
    end
  end

  defp extract_typed_values(props, key) do
    case Map.get(props, key) do
      nil ->
        []

      values ->
        Enum.map(values, fn {value, type} ->
          value = value |> String.replace("tel:", "") |> String.replace("mailto:", "")
          %{"value" => value, "type" => type || "other"}
        end)
    end
  end

  defp unescape(text) do
    # Neutralize the escaped backslashes first (with a placeholder). Then a literal
    # "\\n" decodes to "\n" and not to a newline. Servant.CalDAV.ICS.unescape/1
    # does the same.
    text
    |> String.replace("\\\\", "\0")
    |> String.replace("\\n", "\n")
    |> String.replace("\\N", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\0", "\\")
  end

  # --- Entry builder ---

  defp build_entry(contact, state, source, raw) do
    subtitle_parts =
      [
        contact.org,
        contact.title,
        contact.emails |> Enum.map(& &1["value"]) |> List.first()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")

    title =
      if subtitle_parts != "" do
        "#{contact.display_name} - #{subtitle_parts}"
      else
        contact.display_name
      end

    fields = %{
      "display_name" => contact.display_name,
      "emails" => contact.emails,
      "phones" => contact.phones,
      "org" => contact.org,
      "title" => contact.title,
      "url" => contact.url,
      "note" => contact.note,
      "birthday" => contact.birthday,
      "address" => contact.address,
      "source_name" => state.source_name
    }

    data =
      fields
      |> Map.merge(raw_payload(raw))
      |> Map.merge(photo_payload(contact, raw, state))

    %{
      "kind" => "contact",
      "source" => source,
      "external_id" => contact.uid,
      "title" => title,
      "occurred_at" =>
        parse_birthday(contact.birthday) || DateTime.truncate(DateTime.utc_now(), :second),
      "data" => data,
      "metadata" => %{}
    }
  end

  # A vCard contains its photo inline, encoded in base64. The decode of the photo
  # into a stored file gives the contact the same avatar as a photo uploaded from
  # the app. A photo left in the card shows only on a phone.
  #
  # Imports only. A feed fetched again on a schedule writes the same file again
  # and again, and its entries are skipped as duplicates anyway.
  defp photo_payload(_contact, nil, _state), do: %{}

  defp photo_payload(contact, _raw, state) do
    with user_id when is_binary(user_id) <- Map.get(state, :user_id),
         {:ok, binary} <- decode_photo(contact.photo),
         url when is_binary(url) <- store_photo(user_id, binary) do
      %{"photo" => url}
    else
      _ -> %{}
    end
  end

  defp decode_photo(nil), do: :error

  defp decode_photo(value) do
    cond do
      # vCard 4.0: PHOTO:data:image/jpeg;base64,<...>
      String.starts_with?(value, "data:") ->
        case String.split(value, "base64,", parts: 2) do
          [_prefix, encoded] -> decode_photo_bytes(encoded)
          _ -> :error
        end

      # A remote photo is a link, not a payload. To fetch it, the server must
      # call the host that the file names, whatever that host is.
      String.starts_with?(value, "http") ->
        :error

      # vCard 3.0: PHOTO;ENCODING=b;TYPE=JPEG:<...>
      true ->
        decode_photo_bytes(value)
    end
  end

  defp decode_photo_bytes(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, binary} when byte_size(binary) <= @max_photo_bytes -> {:ok, binary}
      _ -> :error
    end
  end

  defp store_photo(user_id, binary) do
    workspace = Storage.tmp_workspace(user_id)

    try do
      path = Path.join(workspace, "photo#{photo_extension(binary)}")
      File.write!(path, binary)

      case Storage.store_app_file(user_id, "contacts", path, ext: Path.extname(path)) do
        {:ok, relative, _absolute} -> Storage.public_url(relative)
        _ -> nil
      end
    rescue
      # A photo that cannot be written (bad bytes, full disk) costs the avatar,
      # not the import. The contact itself is still imported.
      _ -> nil
    after
      Storage.cleanup_tmp(workspace)
    end
  end

  # The TYPE param is optional and often wrong. The bytes are not.
  defp photo_extension(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: ".jpg"

  defp photo_extension(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>),
    do: ".png"

  defp photo_extension(<<"GIF8", _rest::binary>>), do: ".gif"
  defp photo_extension(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: ".webp"
  defp photo_extension(_binary), do: ".jpg"

  # `Servant.CardDAV.VCard.to_vcf/2` serves this payload back unchanged until an
  # edit of the contact in Servant. That is how a photo gets to a phone. These
  # are the same keys that a CardDAV PUT stores, so the two paths round-trip in
  # the same way.
  defp raw_payload(nil), do: %{}

  defp raw_payload(raw) do
    %{
      "carddav_vcf" => raw,
      "carddav_vcf_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp parse_birthday(nil), do: nil

  defp parse_birthday(str) do
    str = String.trim(str)

    cond do
      # 1990-01-15
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, str) ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end

      # 19900115
      Regex.match?(~r/^\d{8}$/, str) ->
        <<y::binary-4, m::binary-2, d::binary-2>> = str

        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end

      true ->
        nil
    end
  end
end
