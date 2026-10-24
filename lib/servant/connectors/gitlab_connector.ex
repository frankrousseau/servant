defmodule Servant.Connectors.GitlabConnector do
  @moduledoc """
  Connector that fetches the commit metadata of the user from GitLab.

  GitLab has no commit search across projects. As a result, each sync lists
  the projects that the user of the token is a member of. Then it walks the
  commits of each project (all branches), filtered by the configured author. A
  map of `committed_date` cursors, one per project, keeps the syncs
  incremental. The `since` bound is inclusive, and the upsert of the entries
  on `external_id` (the sha) deduplicates the overlap.

  Works with gitlab.com and self-hosted instances (instance URL setting).
  The connector stores only the commit metadata:

  - project
  - sha
  - message
  - author
  - dates
  - URL

  It stores no diffs and no per-commit stats.
  """

  use Servant.Connectors.Connector

  @default_base_url "https://gitlab.com"
  @per_page 100

  @impl true
  def id, do: "gitlab"

  @impl true
  def name, do: "GitLab"

  @impl true
  def required_credentials, do: [:token, :author]

  @impl true
  def kind, do: "commit"

  @impl true
  def init(_credentials, config) do
    token = config_value(config, "token")
    author = config_value(config, "author")

    base_url =
      config
      |> config_value("base_url", @default_base_url)
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      is_nil(token) or token == "" ->
        {:error, "token is required"}

      is_nil(author) or author == "" ->
        {:error, "author is required"}

      true ->
        {:ok,
         %{
           token: token,
           author: author,
           base_url: if(base_url == "", do: @default_base_url, else: base_url),
           cursors: config_value(config, "cursors", %{})
         }}
    end
  end

  @impl true
  def persisted_config(state) do
    %{"cursors" => state.cursors}
  end

  @impl true
  def sync(state) do
    case fetch_projects(state, 1, []) do
      {:ok, projects} ->
        {entries, cursors} =
          Enum.reduce(projects, {[], state.cursors}, fn project, {acc, cursors} ->
            key = to_string(project["id"])
            cursor = cursors[key]

            case fetch_commits(state, project["id"], cursor, 1, []) do
              {:ok, commits} ->
                new_cursor = latest_committed_date(commits) || cursor

                {acc ++ Enum.map(commits, &build_entry(&1, project)),
                 Map.put(cursors, key, new_cursor)}

              {:error, _reason} ->
                # Skip this project (revoked access, rate limit). Keep its old
                # cursor so that the next sync retries from there.
                {acc, cursors}
            end
          end)

        # Drop the cursors of the projects that the user no longer belongs to.
        keys = Enum.map(projects, &to_string(&1["id"]))
        {:ok, entries, %{state | cursors: Map.take(cursors, keys)}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # --- API fetching ---

  defp fetch_projects(state, page, acc) do
    params = [membership: true, per_page: @per_page, page: page]

    case api_get(state, "/api/v4/projects", params) do
      {:ok, projects} when is_list(projects) ->
        all = acc ++ projects

        if length(projects) == @per_page do
          fetch_projects(state, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, _other} ->
        {:error, "GitLab returned an unexpected projects payload"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_commits(state, project_id, cursor, page, acc) do
    params =
      [all: true, author: state.author, per_page: @per_page, page: page] ++
        if(cursor, do: [since: cursor], else: [])

    case api_get(state, "/api/v4/projects/#{project_id}/repository/commits", params) do
      {:ok, commits} when is_list(commits) ->
        all = acc ++ commits

        if length(commits) == @per_page do
          fetch_commits(state, project_id, cursor, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, _other} ->
        {:error, "GitLab returned an unexpected commits payload"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_get(state, path, params) do
    url = state.base_url <> path
    headers = [{"private-token", state.token}]

    case Req.get(url, Servant.HTTP.req_options(headers: headers, params: params)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Unauthorized: check your GitLab token"}

      {:ok, %Req.Response{status: 429}} ->
        {:error, "GitLab rate limit exceeded, try again later"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitLab API error #{status}"}

      {:error, reason} ->
        {:error, "HTTP error: #{inspect(reason)}"}
    end
  end

  # The committed dates contain the local UTC offset of the committer. Compare
  # them as parsed DateTimes, never lexicographically.
  defp latest_committed_date(commits) do
    commits
    |> Enum.flat_map(fn commit ->
      case DateTime.from_iso8601(commit["committed_date"] || "") do
        {:ok, dt, _offset} -> [dt]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      dates -> dates |> Enum.max(DateTime) |> DateTime.to_iso8601()
    end
  end

  # --- Entry building ---

  @doc false
  def build_entry(commit, project) do
    repo = project["path_with_namespace"]
    message = commit["message"] || ""
    [first_line | _] = String.split(message, "\n", parts: 2)

    # from_iso8601 already normalizes offset datetimes to UTC.
    occurred_at =
      case DateTime.from_iso8601(commit["authored_date"] || "") do
        {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
        _ -> DateTime.truncate(DateTime.utc_now(), :second)
      end

    %{
      "kind" => "commit",
      "source" => "gitlab",
      "external_id" => commit["id"],
      "title" => "#{repo} - #{first_line}",
      "occurred_at" => occurred_at,
      "data" => %{
        "repo" => repo,
        "sha" => commit["id"],
        "message" => message,
        "html_url" => commit["web_url"],
        "author_name" => commit["author_name"],
        "author_email" => commit["author_email"],
        "authored_at" => commit["authored_date"],
        "committed_at" => commit["committed_date"]
      },
      "metadata" => %{
        "repo_private" => project["visibility"] != "public"
      }
    }
  end
end
