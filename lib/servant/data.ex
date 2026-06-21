defmodule Servant.Data do
  @moduledoc """
  The Data context. All functions are scoped by user_id.
  """

  import Ecto.Query
  alias Servant.Repo
  alias Servant.Data.Entry

  @default_per_page 50

  def list_entries(user_id, filters \\ %{}) do
    Entry
    |> where(user_id: ^user_id)
    |> apply_filters(filters)
    |> apply_sort(filters)
    |> apply_pagination(filters)
    |> Repo.all()
  end

  def all_entries(user_id) do
    Entry
    |> where(user_id: ^user_id)
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

  def update_entry(user_id, id, attrs) do
    entry = get_entry!(user_id, id)

    result =
      entry
      |> Entry.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, entry} ->
        broadcast(user_id, {:entry_updated, entry})
        {:ok, entry}

      error ->
        error
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

  defp delete_entry_file(%{data: %{"path" => path}}) when is_binary(path) and path != "" do
    Servant.Storage.delete_public_file(path)
  end

  defp delete_entry_file(_entry), do: :ok

  def list_kinds(user_id) do
    Entry
    |> where(user_id: ^user_id)
    |> select([e], e.kind)
    |> distinct(true)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:kind, kind}, q when is_binary(kind) ->
        where(q, kind: ^kind)

      {:source, source}, q when is_binary(source) ->
        where(q, source: ^source)

      {:from, from}, q when is_binary(from) ->
        case DateTime.from_iso8601(from) do
          {:ok, dt, _} -> where(q, [e], e.occurred_at >= ^dt)
          _ -> q
        end

      {:to, to}, q when is_binary(to) ->
        case DateTime.from_iso8601(to) do
          {:ok, dt, _} -> where(q, [e], e.occurred_at <= ^dt)
          _ -> q
        end

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

  defp apply_sort(query, %{"sort" => "inserted_at"}), do: order_by(query, desc: :inserted_at)
  defp apply_sort(query, %{sort: "inserted_at"}), do: order_by(query, desc: :inserted_at)
  defp apply_sort(query, _), do: order_by(query, desc: :occurred_at, desc: :inserted_at)

  defp apply_pagination(query, filters) do
    per_page =
      case filters do
        %{"per_page" => pp} -> parse_int(pp, @default_per_page)
        %{per_page: pp} -> parse_int(pp, @default_per_page)
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

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Servant.PubSub, "data:#{user_id}", message)
  end
end
