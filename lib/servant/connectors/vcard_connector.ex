defmodule Servant.Connectors.VCardConnector do
  @moduledoc """
  Connector that imports contacts from a vCard (.vcf) file or URL.
  Supports vCard 3.0 and 4.0 formats.
  """

  use Servant.Connectors.Connector

  require Logger

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
    url = Map.get(config, "url") || Map.get(config, :url)
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
  Called by the file import endpoint.
  """
  def import_vcard(vcf_content, state) do
    entries = build_entries(vcf_content, state)
    {:ok, entries}
  end

  defp build_entries(body, state) do
    body
    |> parse_vcards()
    |> Enum.map(&build_entry(&1, state))
  end

  defp fetch_vcf(url) do
    case Req.get(url, Servant.HTTP.req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- vCard parser ---

  @doc false
  def parse_vcards(body) do
    body
    |> unfold_lines()
    |> extract_vcards()
    |> Enum.map(&parse_vcard/1)
    |> Enum.reject(&is_nil/1)
  end

  defp unfold_lines(text) do
    text
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/)
  end

  defp extract_vcards(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {cards, current} ->
      cond do
        String.starts_with?(line, "BEGIN:VCARD") ->
          {cards, []}

        String.starts_with?(line, "END:VCARD") and is_list(current) ->
          {[Enum.reverse(current) | cards], nil}

        is_list(current) ->
          {cards, [line | current]}

        true ->
          {cards, current}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_vcard(lines) do
    props = Enum.reduce(lines, %{}, fn line, acc ->
      case parse_property(line) do
        {key, value} -> Map.update(acc, key, [value], &(&1 ++ [value]))
        nil -> acc
      end
    end)

    fn_name = get_first(props, "FN")
    n_parts = get_first(props, "N")

    # Build a display name
    display_name =
      cond do
        fn_name && fn_name != "" -> fn_name
        n_parts -> n_parts |> String.split(";") |> Enum.reject(&(&1 == "")) |> Enum.reverse() |> Enum.join(" ")
        true -> nil
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
        uid: get_first(props, "UID") || display_name
      }
    end
  end

  defp parse_property(line) do
    case String.split(line, ":", parts: 2) do
      [key_part, value] ->
        # Key may have params like "TEL;TYPE=WORK;VALUE=uri"
        key =
          key_part
          |> String.split(";")
          |> List.first()
          |> String.upcase()

        type_param = extract_type_param(key_part)
        {key, {String.trim(value) |> unescape(), type_param}}

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
    text
    |> String.replace("\\n", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  # --- Entry builder ---

  defp build_entry(contact, state) do
    subtitle_parts =
      [
        contact.org,
        contact.title,
        contact.emails |> Enum.map(& &1["value"]) |> List.first()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" — ")

    title =
      if subtitle_parts != "" do
        "#{contact.display_name} — #{subtitle_parts}"
      else
        contact.display_name
      end

    %{
      "kind" => "contact",
      "source" => "vcard",
      "external_id" => contact.uid,
      "title" => title,
      "occurred_at" => parse_birthday(contact.birthday) || (DateTime.utc_now() |> DateTime.truncate(:second)),
      "data" => %{
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
      },
      "metadata" => %{}
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
