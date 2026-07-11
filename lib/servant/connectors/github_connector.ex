defmodule Servant.Connectors.GithubConnector do
  @moduledoc """
  Connector that fetches the user's commit metadata from GitHub.

  Uses the commit Search API with `author:<username>`, so it covers every
  repository the personal access token can see (public and private) without
  maintaining a repo list. Only commit metadata is stored: repo, sha, message,
  author, dates, URL; no diffs or per-commit stats.

  Search results are capped at 1000 per query, so the sync walks history in
  ascending author-date windows, advancing a persisted `last_author_date`
  cursor. The cursor comparison is inclusive (`>=`) to avoid skipping
  same-second commits; the resulting overlap is deduplicated by the entries
  upsert on `external_id` (the commit sha).
  """

  use Servant.Connectors.Connector

  @api_base "https://api.github.com"
  @per_page 100
  # GitHub Search returns at most 1000 results per query
  @search_cap 1000

  @impl true
  def id, do: "github"

  @impl true
  def name, do: "GitHub"

  @impl true
  def required_credentials, do: [:token, :username]

  @impl true
  def kind, do: "commit"

  @impl true
  def init(_credentials, config) do
    token = config_value(config, "token")
    username = config_value(config, "username")

    cond do
      is_nil(token) or token == "" ->
        {:error, "token is required"}

      is_nil(username) or username == "" ->
        {:error, "username is required"}

      true ->
        {:ok,
         %{
           token: token,
           username: username,
           last_author_date: config_value(config, "last_author_date")
         }}
    end
  end

  @impl true
  def persisted_config(state) do
    %{"last_author_date" => state.last_author_date}
  end

  @impl true
  def sync(state) do
    case fetch_all_commits(state, state.last_author_date, []) do
      {:ok, items, new_cursor} ->
        {:ok, Enum.map(items, &build_entry/1), %{state | last_author_date: new_cursor}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # --- Commit fetching ---

  # Walks search windows until the whole history since `cursor` is covered.
  # Each window pages up to the 1000-result search cap; when more results
  # remain, the cursor advances to the newest author date seen and a new
  # window starts.
  defp fetch_all_commits(state, cursor, acc) do
    case fetch_window(state, cursor) do
      {:ok, items, total} ->
        all = acc ++ items
        last_date = last_author_date(items) || cursor

        if length(items) >= @search_cap and total > length(items) and last_date != cursor do
          fetch_all_commits(state, last_date, all)
        else
          {:ok, all, last_date}
        end

      {:error, reason} ->
        # Keep the progress made before a mid-backfill error (rate limit,
        # network); the persisted cursor lets the next sync resume from there
        if acc == [] do
          {:error, reason}
        else
          {:ok, acc, cursor}
        end
    end
  end

  defp fetch_window(state, cursor) do
    fetch_page(state, cursor, 1, [])
  end

  defp fetch_page(state, cursor, page, acc) do
    query = URI.encode_www_form(search_query(state.username, cursor))

    url =
      "#{@api_base}/search/commits" <>
        "?q=#{query}&sort=author-date&order=asc&per_page=#{@per_page}&page=#{page}"

    headers = [
      {"authorization", "Bearer #{state.token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"}
    ]

    case Req.get(url, Servant.HTTP.req_options(headers: headers)) do
      {:ok, %Req.Response{status: 200, body: %{"items" => items, "total_count" => total}}} ->
        all = acc ++ items

        if length(items) == @per_page and length(all) < @search_cap do
          fetch_page(state, cursor, page + 1, all)
        else
          {:ok, all, total}
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Unauthorized: check your GitHub token"}

      {:ok, %Req.Response{status: status}} when status in [403, 429] ->
        {:error, "GitHub rate limit exceeded, try again later"}

      {:ok, %Req.Response{status: 422, body: body}} ->
        msg = if is_map(body), do: body["message"], else: nil
        {:error, "GitHub rejected the search#{if msg, do: ": #{msg}", else: ""}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitHub API error #{status}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  defp search_query(username, nil), do: "author:#{username}"
  defp search_query(username, cursor), do: "author:#{username} author-date:>=#{cursor}"

  # Items are sorted by ascending author date, so the last one is the newest
  defp last_author_date(items) do
    case List.last(items) do
      nil -> nil
      item -> get_in(item, ["commit", "author", "date"])
    end
  end

  # --- Entry building ---

  @doc false
  def build_entry(item) do
    commit = item["commit"] || %{}
    author = commit["author"] || %{}
    repo = get_in(item, ["repository", "full_name"])
    message = commit["message"] || ""
    [first_line | _] = String.split(message, "\n", parts: 2)

    occurred_at =
      case DateTime.from_iso8601(author["date"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> DateTime.truncate(DateTime.utc_now(), :second)
      end

    %{
      "kind" => "commit",
      "source" => "github",
      "external_id" => item["sha"],
      "title" => "#{repo} - #{first_line}",
      "occurred_at" => occurred_at,
      "data" => %{
        "repo" => repo,
        "sha" => item["sha"],
        "message" => message,
        "html_url" => item["html_url"],
        "author_name" => author["name"],
        "author_email" => author["email"],
        "authored_at" => author["date"],
        "committed_at" => get_in(commit, ["committer", "date"])
      },
      "metadata" => %{
        "repo_private" => get_in(item, ["repository", "private"])
      }
    }
  end
end
