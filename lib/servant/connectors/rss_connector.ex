defmodule Servant.Connectors.RSSConnector do
  @moduledoc """
  Example connector that reads an RSS feed and creates article entries.
  """

  use Servant.Connectors.Connector

  require Logger

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
              "external_id" => item.link || item.title,
              "title" => item.title,
              "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second),
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
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 15_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, parse_rss(body)}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
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
        description: extract_tag(item_xml, "description")
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
end
