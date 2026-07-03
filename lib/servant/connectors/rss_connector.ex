defmodule Servant.Connectors.RSSConnector do
  @moduledoc """
  Example connector that reads an RSS feed and creates article entries.
  """

  use Servant.Connectors.Connector

  require Logger

  @rfc822_months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @impl true
  def id, do: "rss"

  @impl true
  def name, do: "RSS Feed"

  @impl true
  def required_credentials, do: []

  @impl true
  def kind, do: "article"

  @impl true
  def init(_credentials, config) do
    case config_value(config, "url") do
      nil -> {:error, :missing_url}
      url -> {:ok, %{url: url}}
    end
  end

  @impl true
  def sync(%{url: url} = state) do
    case fetch_and_parse(url) do
      {:ok, items} ->
        entries =
          Enum.map(items, fn item ->
            %{
              "kind" => "article",
              "source" => "rss",
              "external_id" => external_id(item),
              "title" => item.title,
              "occurred_at" => parse_pub_date(item.pub_date),
              "data" => %{"link" => item.link, "description" => item.description},
              "metadata" => %{"feed_url" => url}
            }
          end)

        {:ok, entries, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def default_schedule, do: "every_hour"

  defp fetch_and_parse(url) do
    with :ok <- Servant.HTTP.ensure_public_url(url),
         {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, Servant.HTTP.req_options(decode_body: false, verify: false)) do
      {:ok, parse_rss(body)}
    else
      {:error, :blocked_url} -> {:error, "Refusing to fetch a non-public URL"}
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_rss(xml) when is_binary(xml) do
    # Simple regex-based RSS parsing for <item> elements
    ~r/<item>(.*?)<\/item>/s
    |> Regex.scan(xml)
    |> Enum.map(fn [_, item_xml] ->
      %{
        title: extract_tag(item_xml, "title"),
        link: extract_tag(item_xml, "link"),
        description: extract_tag(item_xml, "description"),
        pub_date: extract_tag(item_xml, "pubDate") || extract_tag(item_xml, "dc:date")
      }
    end)
  end

  defp extract_tag(xml, tag) do
    case Regex.run(~r/<#{tag}[^>]*>(.*?)<\/#{tag}>/s, xml) do
      [_, content] -> content |> String.trim() |> strip_cdata()
      _ -> nil
    end
  end

  defp strip_cdata(text) do
    text
    |> String.replace(~r/^<!\[CDATA\[/, "")
    |> String.replace(~r/\]\]>$/, "")
  end

  # A stable, non-nil identifier so the (user_id, source, external_id) unique
  # constraint actually dedupes. SQLite treats NULLs as distinct, so a nil
  # external_id would let the same article be inserted again on every sync.
  @doc false
  def external_id(item) do
    item.link || item.title || content_hash(item)
  end

  defp content_hash(item) do
    raw = "#{item.title}|#{item.link}|#{item.description}"
    "sha256:" <> (:crypto.hash(:sha256, raw) |> Base.encode16(case: :lower))
  end

  # Parse the feed's own timestamp so entries sort chronologically. Falls back
  # to now/0 only when the feed provides no parseable date.
  @doc false
  def parse_pub_date(nil), do: now()

  def parse_pub_date(str) do
    str = String.trim(str)

    case parse_iso8601(str) do
      {:ok, dt} ->
        dt

      :error ->
        case parse_rfc822(str) do
          {:ok, dt} -> dt
          :error -> now()
        end
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # dc:date / Atom feeds use ISO 8601.
  defp parse_iso8601(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  # RSS <pubDate> uses RFC 822, e.g. "Mon, 06 Sep 2021 16:45:00 +0000" / "… GMT".
  defp parse_rfc822(str) do
    re =
      ~r/(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4})?/

    case Regex.run(re, str, capture: :all_but_first) do
      nil ->
        :error

      caps ->
        [day, mon, year, hour, min, sec, tz] = caps ++ List.duplicate("", 7 - length(caps))
        month = Map.get(@rfc822_months, String.downcase(String.slice(mon, 0, 3)))

        with false <- is_nil(month),
             {:ok, date} <- Date.new(to_int(year), month, to_int(day)),
             {:ok, time} <- Time.new(to_int(hour), to_int(min), to_int(sec)),
             {:ok, naive} <- NaiveDateTime.new(date, time) do
          dt = naive |> DateTime.from_naive!("Etc/UTC") |> apply_offset(tz)
          {:ok, DateTime.truncate(dt, :second)}
        else
          _ -> :error
        end
    end
  end

  defp to_int(""), do: 0

  defp to_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Convert a parsed local time to UTC using the numeric offset (UTC = local - offset).
  # Named zones (GMT/UT/Z) aren't captured and are treated as UTC.
  defp apply_offset(dt, <<sign, h1, h2, m1, m2>>) when sign in [?+, ?-] do
    offset_min = to_int(<<h1, h2>>) * 60 + to_int(<<m1, m2>>)
    offset_min = if sign == ?-, do: -offset_min, else: offset_min
    DateTime.add(dt, -offset_min * 60, :second)
  end

  defp apply_offset(dt, _), do: dt
end
