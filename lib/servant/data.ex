defmodule Servant.Data do
  @moduledoc """
  The Data context. All functions are scoped by user_id.
  """

  import Ecto.Query
  alias Servant.Data.Entry
  alias Servant.Repo

  @default_per_page 50
  @max_per_page 1000

  @doc """
  Clamps a requested `per_page` into `[1, #{@max_per_page}]`, falling back to the
  default for non-integers. Shared with the controller so pagination metadata
  (total_pages) and the query LIMIT agree — and so `per_page=0` can't reach a
  `total/per_page` division or `per_page` negative a `LIMIT -1`.
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
  Per-kind daily entry counts (UTC days) for the trailing `days` window,
  as `%{kind => %{"YYYY-MM-DD" => count}}`. Powers the dashboard sparklines.
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

  @doc """
  Bulk-inserts entries for a user in a single `insert_all` (with
  `on_conflict: :nothing` on the unique key), then emits **one** aggregated
  broadcast instead of one INSERT + one PubSub message per entry. Used by
  connector syncs / file imports where a sync can yield thousands of entries.

  Returns `{:ok, inserted_count}`.
  """
  # Chunk size for bulk inserts: each row binds ~11 columns, so 500 rows ≈ 5.5k
  # bound params — comfortably under SQLite's default 32k variable limit even if
  # the schema grows, while keeping the number of round-trips low.
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
      kind: field(attrs, :kind),
      source: field(attrs, :source),
      external_id: field(attrs, :external_id),
      title: field(attrs, :title),
      occurred_at: normalize_datetime(field(attrs, :occurred_at)),
      data: field(attrs, :data) || %{},
      metadata: field(attrs, :metadata) || %{},
      inserted_at: now,
      updated_at: now
    }
  end

  defp field(attrs, key), do: Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)

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

    # Notes are entries too, but editing one here would skip the Notes context's
    # link re-sync / rename propagation, leaving note_links stale. Route note
    # edits through Servant.Notes instead. (Deletes are fine: note_links rows are
    # cleaned by the FK on_delete.)
    if entry.kind == "note" do
      {:error, :notes_api_required}
    else
      case entry |> Entry.changeset(attrs) |> Repo.update() do
        {:ok, entry} ->
          broadcast(user_id, {:entry_updated, entry})
          {:ok, entry}

        error ->
          error
      end
    end
  end

  def delete_entry(user_id, id) do
    entry = get_entry!(user_id, id)
    delete_entry_file(entry)

    result = Repo.delete(entry)

    case result do
      {:ok, entry} ->
        broadcast(user_id, {:entry_deleted, entry})
        {:ok, entry}

      error ->
        error
    end
  end

  defp delete_entry_file(%{data: data}) when is_map(data) do
    delete_public_path(data["path"])
    delete_public_path(data["thumb_path"])
    :ok
  end

  defp delete_entry_file(_entry), do: :ok

  defp delete_public_path(path) when is_binary(path) and path != "" do
    Servant.Storage.delete_public_file(path)
  end

  defp delete_public_path(_), do: :ok

  def list_kinds(user_id) do
    Entry
    |> where(user_id: ^user_id)
    |> select([e], e.kind)
    |> distinct(true)
    |> Repo.all()
  end

  # Filters arrive with either atom keys (internal callers/tests) or string
  # keys (controller params). Normalize once to strings so a single set of
  # clauses covers both — a filter added on only one form can't slip through.
  defp apply_filters(query, filters) do
    filters
    |> stringify_keys()
    |> Enum.reduce(query, fn
      {"kind", kind}, q when is_binary(kind) ->
        where(q, kind: ^kind)

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
