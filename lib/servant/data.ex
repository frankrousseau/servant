defmodule Servant.Data do
  @moduledoc """
  The Data context. user_id scopes all the functions.
  """

  import Ecto.Query
  alias Servant.Data.Entry
  alias Servant.Repo

  @default_per_page 50
  @max_per_page 1000

  @doc """
  Clamps a requested `per_page` into `[1, #{@max_per_page}]`. Uses the default
  for a value that is not an integer. The controller shares this function, so
  that the pagination metadata (total_pages) and the query LIMIT agree. It
  also prevents a `total/per_page` division with `per_page=0` and a
  `LIMIT -1` with a negative `per_page`.
  """
  def clamp_per_page(val) do
    val |> Servant.Util.parse_int(@default_per_page) |> max(1) |> min(@max_per_page)
  end

  def list_entries(user_id, filters \\ %{}) do
    Entry
    |> where(user_id: ^user_id)
    |> apply_filters(filters)
    |> apply_sort(filters)
    |> apply_pagination(filters)
    |> Repo.all()
  end

  def all_entries(user_id, filters \\ %{}) do
    Entry
    |> where(user_id: ^user_id)
    |> apply_filters(filters)
    |> order_by(desc: :occurred_at, desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns all the entries of the given kinds with occurred_at >= from, newest
  first, without pagination. The agent recipes use it. A truncated aggregate
  gives a wrong number, and no token cost makes a cap necessary.
  """
  def entries_window(user_id, kinds, from_dt) do
    Entry
    |> where(user_id: ^user_id)
    |> where([e], e.kind in ^kinds)
    |> where([e], e.occurred_at >= ^from_dt)
    |> order_by(desc: :occurred_at, desc: :inserted_at)
    |> Repo.all()
  end

  def count_entries(user_id, filters \\ %{}) do
    Entry
    |> where(user_id: ^user_id)
    |> apply_filters(filters)
    |> Repo.aggregate(:count)
  end

  def stats(user_id) do
    Entry
    |> where(user_id: ^user_id)
    |> group_by(:kind)
    |> select([e], {e.kind, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Returns the daily counts of entries for each kind (UTC days) in the window
  of the last `days` days, as `%{kind => %{"YYYY-MM-DD" => count}}`. The
  dashboard sparklines use it.
  """
  def daily_stats(user_id, days) when is_integer(days) and days > 0 do
    cutoff =
      Date.utc_today()
      |> Date.add(-(days - 1))
      |> NaiveDateTime.new!(~T[00:00:00])

    Entry
    |> where(user_id: ^user_id)
    |> where([e], e.inserted_at >= ^cutoff)
    |> group_by([e], [e.kind, fragment("date(?)", e.inserted_at)])
    |> select([e], {e.kind, fragment("date(?)", e.inserted_at), count(e.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {kind, day, count}, acc ->
      Map.update(acc, kind, %{day => count}, &Map.put(&1, day, count))
    end)
  end

  @doc """
  Aggregates the entries in buckets. The value is the COUNT of the entries or
  the SUM of a numeric `data` field. The buckets are the local day, week,
  month or year in the given IANA timezone (a week bucket is the Monday of
  the ISO week). Takes the same filters as `list_entries/2`. Skips the entries
  without `occurred_at`. Returns the sorted list
  `[%{bucket: "YYYY-MM-DD" | "YYYY-MM" | "YYYY", value: number}]`.
  """
  def aggregate_entries(user_id, filters, opts) do
    tz = opts[:tz] || "UTC"
    bucket = opts[:bucket] || "day"

    query =
      Entry
      |> where(user_id: ^user_id)
      |> where([e], not is_nil(e.occurred_at))
      |> apply_filters(filters)

    rows =
      case opts do
        %{agg: "sum", field: field} ->
          path = "$." <> field

          query
          |> select(
            [e],
            {e.occurred_at, fragment("CAST(json_extract(?, ?) AS REAL)", e.data, ^path)}
          )
          |> Repo.all()

        _ ->
          query
          |> select([e], {e.occurred_at, 1})
          |> Repo.all()
      end

    # ponytail: Elixir does the tz shift for each row. Change to a segmented
    # SQL GROUP BY (one constant offset for each DST segment) if the windows
    # reach 100k rows or more.
    rows
    |> Enum.group_by(
      fn {dt, _value} ->
        dt |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> bucket_key(bucket)
      end,
      fn {_dt, value} -> value || 0 end
    )
    |> Enum.map(fn {key, values} -> %{bucket: key, value: Enum.sum(values)} end)
    |> Enum.sort_by(& &1.bucket)
  end

  defp bucket_key(date, "week"), do: date |> Date.beginning_of_week() |> Date.to_iso8601()
  defp bucket_key(date, "month"), do: Calendar.strftime(date, "%Y-%m")
  defp bucket_key(date, "year"), do: Integer.to_string(date.year)
  defp bucket_key(date, _day), do: Date.to_iso8601(date)

  def list_sources(user_id) do
    Entry
    |> where(user_id: ^user_id)
    |> select([e], e.source)
    |> distinct(true)
    |> Repo.all()
  end

  def get_entry!(user_id, id) do
    Repo.get_by!(Entry, id: id, user_id: user_id)
  end

  def create_entry(user_id, attrs) do
    # Notes must go through Servant.Notes, which parses their wikilinks and
    # mentions into note_links. A note created here leaves the graph
    # incomplete. Agent memory files must go through Servant.AgentMemory, which
    # parses the path and gives the body its server-side sha256. A file created
    # here skips both. This guard mirrors the guard in update_entry/3.
    cond do
      get_attr(attrs, :kind) == "note" ->
        {:error, :notes_api_required}

      get_attr(attrs, :kind) == "agent_memory" ->
        {:error, :agent_memory_api_required}

      true ->
        result =
          %Entry{user_id: user_id}
          |> Entry.changeset(attrs)
          |> Repo.insert()

        case result do
          {:ok, entry} ->
            broadcast(user_id, {:entry_created, entry})
            {:ok, entry}

          error ->
            error
        end
    end
  end

  @doc """
  Bulk-inserts entries for a user with one `insert_all` for each chunk of
  `@insert_chunk_size` rows (with `on_conflict: :nothing` on the unique key).
  Then emits **one** aggregated
  broadcast, not one INSERT and one PubSub message for each entry. The
  connector syncs and the file imports use it, because a sync can give
  thousands of entries.

  Returns `{:ok, inserted_count}`.
  """
  # The chunk size for bulk inserts. Each row binds approximately 11 columns,
  # so 500 rows are approximately 5.5k bound params. This is well below the
  # default 32k variable limit of SQLite, even if the schema grows. It also
  # keeps the number of round-trips low.
  @insert_chunk_size 500

  def create_entries(_user_id, []), do: {:ok, 0}

  def create_entries(user_id, attrs_list) when is_list(attrs_list) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    count =
      attrs_list
      |> Stream.map(&entry_row(user_id, &1, now))
      |> Stream.chunk_every(@insert_chunk_size)
      |> Enum.reduce(0, fn rows, acc ->
        {inserted, _} =
          Repo.insert_all(Entry, rows,
            on_conflict: :nothing,
            conflict_target: [:user_id, :source, :external_id]
          )

        acc + inserted
      end)

    if count > 0, do: broadcast(user_id, {:entries_changed, %{count: count}})
    {:ok, count}
  end

  defp entry_row(user_id, attrs, now) do
    %{
      id: Ecto.UUID.generate(),
      user_id: user_id,
      kind: get_attr(attrs, :kind),
      source: get_attr(attrs, :source),
      external_id: get_attr(attrs, :external_id),
      title: get_attr(attrs, :title),
      occurred_at: normalize_datetime(get_attr(attrs, :occurred_at)),
      data: get_attr(attrs, :data) || %{},
      metadata: get_attr(attrs, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp get_attr(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

  defp normalize_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp normalize_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp normalize_datetime(_), do: nil

  def update_entry(user_id, id, attrs) do
    entry = get_entry!(user_id, id)
    target_kind = get_attr(attrs, :kind)

    # Notes are also entries. But an edit of a note here skips the link re-sync
    # and the rename propagation of the Notes context, and note_links becomes
    # stale. Route the note edits through Servant.Notes. (Deletes are safe: the
    # FK on_delete cleans the note_links rows.) Agent memory files have the
    # same guard: an edit here skips the path parse and the sha256 of
    # Servant.AgentMemory.
    cond do
      entry.kind == "note" ->
        {:error, :notes_api_required}

      entry.kind == "agent_memory" or target_kind == "agent_memory" ->
        {:error, :agent_memory_api_required}

      true ->
        case entry |> Entry.changeset(attrs) |> Repo.update() do
          {:ok, entry} ->
            broadcast(user_id, {:entry_updated, entry})
            {:ok, entry}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes each entry that matches the filters (same kind/source/from/to
  semantics as `list_entries/2`). Also deletes the files that the entries
  reference, then emits one aggregated broadcast. The caller must make sure
  that at least one filter is present.

  Returns the number of deleted entries. The FK on_delete cleans the
  note_links rows, the same as for the delete of one entry.
  """
  def delete_entries_matching(user_id, filters) when is_map(filters) do
    base =
      Entry
      |> where(user_id: ^user_id)
      |> apply_filters(filters)

    base
    |> select([e], e.data)
    |> Repo.all()
    |> Enum.each(&delete_entry_file(user_id, %{data: &1}))

    {count, _} = Repo.delete_all(base)

    if count > 0, do: broadcast(user_id, {:entries_changed, %{count: count}})
    count
  end

  def delete_entry(user_id, id) do
    entry = get_entry!(user_id, id)
    delete_entry_file(user_id, entry)

    result = Repo.delete(entry)

    case result do
      {:ok, entry} ->
        broadcast(user_id, {:entry_deleted, entry})
        {:ok, entry}

      error ->
        error
    end
  end

  defp delete_entry_file(user_id, %{data: data}) when is_map(data) do
    delete_public_path(user_id, data["path"])
    delete_public_path(user_id, data["thumb_path"])
    # Photos also have a full-size display JPEG. Without this call, the JPEG
    # stays on disk after the delete (and stays readable through its /files
    # URL).
    delete_public_path(user_id, data["display_path"])
    :ok
  end

  defp delete_entry_file(_user_id, _entry), do: :ok

  defp delete_public_path(user_id, path) when is_binary(path) and path != "" do
    Servant.Storage.delete_public_file(user_id, path)
  end

  defp delete_public_path(_user_id, _path), do: :ok

  def list_kinds(user_id) do
    Entry
    |> where(user_id: ^user_id)
    |> select([e], e.kind)
    |> distinct(true)
    |> Repo.all()
  end

  # The filters come with atom keys (internal callers and tests) or with
  # string keys (controller params). Normalize the keys to strings one time,
  # so that one set of clauses handles the two forms. As a result, no filter
  # applies to only one of the forms.
  defp apply_filters(query, filters) do
    filters
    |> stringify_keys()
    |> Enum.reduce(query, fn
      {"kind", kind}, q when is_binary(kind) ->
        where(q, kind: ^kind)

      {"kinds", kinds}, q when is_list(kinds) ->
        where(q, [e], e.kind in ^kinds)

      {"source", source}, q when is_binary(source) ->
        where(q, source: ^source)

      {"from", from}, q when is_binary(from) ->
        case DateTime.from_iso8601(from) do
          {:ok, dt, _} -> where(q, [e], e.occurred_at >= ^dt)
          _ -> q
        end

      {"to", to}, q when is_binary(to) ->
        case DateTime.from_iso8601(to) do
          {:ok, dt, _} -> where(q, [e], e.occurred_at <= ^dt)
          _ -> q
        end

      # Substring search in the title and in the JSON data text (SQLite LIKE,
      # case-insensitive for ASCII). The command palette uses it.
      {"q", term}, q when is_binary(term) and term != "" ->
        pattern = "%" <> term <> "%"
        where(q, [e], like(e.title, ^pattern) or fragment("? LIKE ?", e.data, ^pattern))

      _, q ->
        q
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp apply_sort(query, %{"sort" => "inserted_at"}), do: order_by(query, desc: :inserted_at)
  defp apply_sort(query, %{sort: "inserted_at"}), do: order_by(query, desc: :inserted_at)
  defp apply_sort(query, _), do: order_by(query, desc: :occurred_at, desc: :inserted_at)

  defp apply_pagination(query, filters) do
    per_page =
      case filters do
        %{"per_page" => pp} -> clamp_per_page(pp)
        %{per_page: pp} -> clamp_per_page(pp)
        _ -> @default_per_page
      end

    page =
      case filters do
        %{"page" => p} -> max(parse_int(p, 1), 1)
        %{page: p} -> max(parse_int(p, 1), 1)
        _ -> 1
      end

    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
  end

  defp parse_int(val, default), do: Servant.Util.parse_int(val, default)

  defp broadcast(user_id, message), do: Servant.Events.broadcast(user_id, message)
end
