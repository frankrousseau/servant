defmodule Servant.AgentMemory do
  @moduledoc """
  Memory and skills of coding agents (Claude Code, Cursor), one `agent_memory`
  entry per file, identified by its path (`external_id`, so the entries unique
  index makes paths unique per user). Agents push and pull through
  `/api/agent_memory`; the app reads, edits and deletes through the same routes.

  Everything derives from the path:

    * `memory/<project>/<file>`: project memory, tool `claude`
    * `skills/<tool>/<name>/<file>` (and deeper): global skill, project `""`
    * `rules/<project>/<file>`: Cursor rules, tool `cursor`
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Events
  alias Servant.Repo

  @kind "agent_memory"
  @source "agent"
  @tools ~w(claude cursor shared)
  @segment ~r/^[A-Za-z0-9._-]+$/

  @doc "Derives project, tool and title from a path."
  @spec parse_path(term) :: {:ok, map} | {:error, :invalid_path}
  def parse_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    with true <- Enum.all?(segments, &valid_segment?/1),
         {:ok, project, tool} <- classify(segments) do
      {:ok,
       %{"path" => path, "project" => project, "tool" => tool, "title" => List.last(segments)}}
    else
      _ -> {:error, :invalid_path}
    end
  end

  def parse_path(_), do: {:error, :invalid_path}

  defp classify(["memory", project, _file | _]), do: {:ok, project, "claude"}
  defp classify(["skills", tool, _name, _file | _]) when tool in @tools, do: {:ok, "", tool}
  defp classify(["rules", project, _file | _]), do: {:ok, project, "cursor"}
  defp classify(_), do: :error

  defp valid_segment?(segment) do
    segment not in [".", ".."] and Regex.match?(@segment, segment)
  end

  @doc """
  Lists a user's files sorted by path. `project` also keeps global files
  (project `""`), `tool` also keeps `shared` ones, so one call returns what a
  session in a repo needs.
  """
  @spec list(String.t(), map) :: [Entry.t()]
  def list(user_id, filters \\ %{}) do
    from(e in Entry,
      where: e.user_id == ^user_id and e.kind == @kind and e.source == ^@source,
      order_by: [asc: e.external_id]
    )
    |> filter_project(filters["project"])
    |> filter_tool(filters["tool"])
    |> Repo.all()
    |> Enum.filter(&valid_entry?/1)
  end

  # A row is only trustworthy once its stored path both re-parses cleanly and
  # still matches the external_id it was upserted under (a row inserted or
  # edited outside upsert_all/2, directly against the entries table, could
  # carry a stale or malicious path in `data`).
  defp valid_entry?(entry) do
    case parse_path(entry.data["path"]) do
      {:ok, _attrs} -> entry.data["path"] == entry.external_id
      {:error, _} -> false
    end
  end

  defp filter_project(query, nil), do: query

  defp filter_project(query, project) do
    where(query, [e], fragment("json_extract(?, '$.project')", e.data) in ^[project, ""])
  end

  defp filter_tool(query, nil), do: query

  defp filter_tool(query, tool) do
    where(query, [e], fragment("json_extract(?, '$.tool')", e.data) in ^[tool, "shared"])
  end

  @doc """
  Upserts `[%{"path", "body"}]` by path in one transaction. Any invalid file
  rejects the whole batch. An unchanged body is left alone (`updated_at` stays).
  A path conflicting with an existing entry (a changeset error on insert or
  update) rolls the whole batch back and returns `{:error, :conflict}`.

  `origin` says who writes. The app (`:app`) curates: its edit marks the file
  `pending: "modified"` so agents apply it over their own copy, and writing a
  soft-deleted path restores it. An agent (`:agent`, the default) takes the
  file back: its push clears `modified`, and a push to a soft-deleted path is
  refused with `{:error, :deleted}` until the app restores it.
  """
  @spec upsert_all(String.t(), list, :agent | :app) ::
          {:ok, [Entry.t()]}
          | {:error, :invalid_path}
          | {:error, :conflict}
          | {:error, :deleted}
  def upsert_all(user_id, files, origin \\ :agent)
      when is_list(files) and origin in [:agent, :app] do
    with {:ok, parsed} <- parse_all(files) do
      parsed
      |> run_upserts(user_id, origin)
      |> case do
        {:ok, entries_and_events} ->
          # Broadcasts fire only once the transaction actually commits, so a
          # rolled-back conflict never announces a change that didn't happen.
          Enum.each(entries_and_events, fn
            {_entry, nil} -> :ok
            {_entry, event} -> Events.broadcast(user_id, event)
          end)

          {:ok, Enum.map(entries_and_events, fn {entry, _event} -> entry end)}

        {:error, reason} when reason in [:conflict, :deleted] ->
          {:error, reason}
      end
    end
  end

  defp run_upserts(parsed, user_id, origin) do
    Repo.transaction(fn ->
      Enum.map(parsed, fn {attrs, body} -> upsert_one(user_id, attrs, body, origin) end)
    end)
  end

  defp parse_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"path" => path, "body" => body}, {:ok, acc} when is_binary(body) ->
        case parse_path(path) do
          {:ok, attrs} -> {:cont, {:ok, [{attrs, body} | acc]}}
          error -> {:halt, error}
        end

      _file, _acc ->
        {:halt, {:error, :invalid_path}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  # Returns `{entry, event | nil}`: the event is broadcast by the caller only
  # once the whole transaction commits, and a changeset error (a path racing
  # another insert/update) rolls the batch back instead of raising.
  defp upsert_one(user_id, attrs, body, origin) do
    sha = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    data = attrs |> Map.delete("title") |> Map.merge(%{"body" => body, "sha256" => sha})

    case get_by_path(user_id, attrs["path"]) do
      nil ->
        %Entry{user_id: user_id, kind: @kind, source: @source}
        |> Entry.changeset(%{
          title: attrs["title"],
          external_id: attrs["path"],
          occurred_at: DateTime.truncate(DateTime.utc_now(), :second),
          data: data
        })
        |> Repo.insert()
        |> case do
          {:ok, entry} -> {entry, {:entry_created, entry}}
          {:error, _changeset} -> Repo.rollback(:conflict)
        end

      %Entry{data: %{"pending" => "deleted"}} when origin == :agent ->
        Repo.rollback(:deleted)

      %Entry{data: %{"sha256" => ^sha, "pending" => "deleted"} = old} = entry ->
        update_data(entry, attrs, Map.delete(old, "pending"))

      %Entry{data: %{"sha256" => ^sha}} = entry ->
        {entry, nil}

      entry ->
        data = if origin == :app, do: Map.put(data, "pending", "modified"), else: data
        update_data(entry, attrs, data)
    end
  end

  defp update_data(entry, attrs, data) do
    entry
    |> Entry.changeset(%{title: attrs["title"], data: data})
    |> Repo.update()
    |> case do
      {:ok, entry} -> {entry, {:entry_updated, entry}}
      {:error, _changeset} -> Repo.rollback(:conflict)
    end
  end

  defp get_by_path(user_id, path) do
    Repo.get_by(Entry, user_id: user_id, kind: @kind, source: @source, external_id: path)
  end

  @doc """
  Soft-deletes the file at `path`: the row stays, marked `pending: "deleted"`,
  so every machine removes its copy at its next pull (a hard delete would
  vanish from the manifest, and the next push from a machine that still has
  the file would bring it back). `purge/2` removes the row for good.
  """
  @spec delete(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def delete(user_id, path) do
    case get_by_path(user_id, path) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, entry} =
          entry
          |> Entry.changeset(%{data: Map.put(entry.data, "pending", "deleted")})
          |> Repo.update()

        Events.broadcast(user_id, {:entry_updated, entry})
        {:ok, entry}
    end
  end

  @doc "Removes the row at `path` for good."
  @spec purge(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def purge(user_id, path) do
    case get_by_path(user_id, path) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok, entry} = Repo.delete(entry)
        Events.broadcast(user_id, {:entry_deleted, entry})
        {:ok, entry}
    end
  end

  @doc "Manifest row for a file; `include_body?` adds the markdown."
  @spec to_json(Entry.t(), boolean) :: map
  def to_json(%Entry{} = entry, include_body? \\ false) do
    body = entry.data["body"] || ""

    base = %{
      id: entry.id,
      path: entry.data["path"],
      project: entry.data["project"],
      tool: entry.data["tool"],
      sha256: entry.data["sha256"],
      size: byte_size(body),
      updated_at: entry.updated_at,
      pending: entry.data["pending"]
    }

    if include_body?, do: Map.put(base, :body, body), else: base
  end
end
