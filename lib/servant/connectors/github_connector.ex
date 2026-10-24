defmodule Servant.Connectors.GithubConnector do
  @moduledoc """
  Connector that fetches the commit metadata of the user from GitHub.

  Uses the commit Search API with `author:<username>`. As a result, it covers
  every repository that the personal access token can see (public and private),
  and no repo list is necessary. The connector stores only the commit metadata:

  - repo
  - sha
  - message
  - author
  - dates
  - URL

  It stores no diffs and no per-commit stats.

  The search also matches copies of repositories that the user contributed to
  (a person who uploads a project again keeps its commit authors). The optional
  `exclude_repos` config (comma-separated `owner/name` or `owner/*`) filters
  out these copies.

  GitHub caps the search results at 1000 per query. As a result, the sync walks
  the history in windows of ascending author date and moves a persisted
  `last_author_date` cursor forward. The cursor comparison is inclusive (`>=`),
  so the sync does not skip commits of the same second. The upsert of the
  entries on `external_id` (the commit sha) deduplicates the overlap.

  The limit of the Search API is ~30 requests/minute. In one sync, the connector
  puts ~2s between consecutive requests. It retries a rate-limited response
  after the advertised delay. As a result, a full backfill of many years
  completes in a single (slow) sync, and a relaunch is not necessary.
  """

  use Servant.Connectors.Connector

  @api_base "https://api.github.com"
  @per_page 100
  # GitHub Search returns at most 1000 results per query.
  @search_cap 1000
  # The Search rate limit is ~30 req/min. Stay slightly below it.
  @throttle_ms 2_100
  @max_rate_limit_wait_ms 90_000

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
           exclude_repos: parse_excludes(config_value(config, "exclude_repos", "")),
           last_author_date: config_value(config, "last_author_date")
         }}
    end
  end

  defp parse_excludes(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.split([",", " ", "\n"], trim: true)
  end

  @impl true
  def persisted_config(state) do
    %{"last_author_date" => state.last_author_date}
  end

  @impl true
  def sync(state) do
    case fetch_all_commits(state, state.last_author_date, []) do
      {:ok, items, new_cursor} ->
        entries =
          items
          |> Enum.reject(
            &excluded_repo?(get_in(&1, ["repository", "full_name"]), state.exclude_repos)
          )
          |> Enum.map(&build_entry/1)

        {:ok, entries, %{state | last_author_date: new_cursor}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc false
  def excluded_repo?(_repo, []), do: false

  def excluded_repo?(repo, patterns) do
    repo = String.downcase(repo || "")
    owner_wildcard = (repo |> String.split("/") |> hd()) <> "/*"
    Enum.any?(patterns, &(&1 == repo or &1 == owner_wildcard))
  end

  # --- Commit fetching ---

  # Walks the search windows until they cover the whole history from `cursor`.
  # Each window pages up to the search cap of 1000 results. When more results
  # remain, the cursor moves to the newest author date seen and a new window
  # starts.
  defp fetch_all_commits(state, cursor, acc) do
    case fetch_window(state, cursor) do
      {:ok, items, total} ->
        all = acc ++ items
        last_date = last_author_date(items) || cursor

        if length(items) >= @search_cap and total > length(items) and last_date != cursor do
          Servant.HTTP.throttle(@throttle_ms)
          fetch_all_commits(state, last_date, all)
        else
          {:ok, all, last_date}
        end

      {:error, reason} ->
        # Keep the progress made before an error in the middle of a backfill
        # (rate limit, network). The persisted cursor lets the next sync resume
        # from there.
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

    case search_request(url, headers) do
      {:ok, %Req.Response{status: 200, body: %{"items" => items, "total_count" => total}}} ->
        all = acc ++ items

        if length(items) == @per_page and length(all) < @search_cap do
          Servant.HTTP.throttle(@throttle_ms)
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

  # Sleeps for the advertised delay after a rate-limited response, then
  # retries. The sync does not fail. A 403 without rate-limit headers (bad
  # scopes) goes to the error handling of the caller.
  defp search_request(url, headers, retries \\ 2) do
    case Req.get(url, Servant.HTTP.req_options(headers: headers)) do
      {:ok, %Req.Response{status: status} = resp}
      when status in [403, 429] and retries > 0 ->
        case rate_limit_wait_ms(resp, System.system_time(:second)) do
          nil ->
            {:ok, resp}

          wait_ms ->
            Servant.HTTP.throttle(wait_ms)
            search_request(url, headers, retries - 1)
        end

      other ->
        other
    end
  end

  @doc false
  def rate_limit_wait_ms(resp, now_unix) do
    retry_after = header_int(resp, "retry-after")
    reset = header_int(resp, "x-ratelimit-reset")
    remaining = header_int(resp, "x-ratelimit-remaining")

    cond do
      retry_after -> clamp_wait(retry_after * 1000)
      remaining == 0 and is_integer(reset) -> clamp_wait((reset - now_unix) * 1000)
      true -> nil
    end
  end

  defp clamp_wait(ms), do: ms |> max(1_000) |> min(@max_rate_limit_wait_ms)

  defp header_int(resp, name) do
    with [value | _] <- Req.Response.get_header(resp, name),
         {n, _} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  defp search_query(username, nil), do: "author:#{username}"
  defp search_query(username, cursor), do: "author:#{username} author-date:>=#{cursor}"

  # The items are in ascending order of author date, so the last one is the newest.
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
