defmodule Servant.FilesDav do
  @moduledoc """
  WebDAV view of the Files app. It shows the `file` entries, with
  `Servant.Storage` as the backend. A folder is an entry with
  `data.is_folder`, and `data.parent_id` gives the hierarchy. The path
  segments resolve in each folder on `data.filename`. The first match wins
  when legacy duplicates exist.

  Read the full file tree one time for each request and walk it in memory.
  Add an index by parent in SQL if the listings become too slow at the scale
  of a personal archive.
  """

  alias Servant.Data
  alias Servant.Storage

  @source "webdav"

  @spec tree(String.t()) :: [Servant.Data.Entry.t()]
  def tree(user_id), do: Data.all_entries(user_id, %{"kind" => "file"})

  def folder?(entry), do: entry.data["is_folder"] == true

  def name(entry) do
    case entry.data["filename"] do
      n when is_binary(n) and n != "" -> n
      _ -> entry.title || "unnamed"
    end
  end

  def children(entries, parent_id) do
    Enum.filter(entries, fn e -> parent_of(e) == parent_id end)
  end

  defp parent_of(entry) do
    case entry.data["parent_id"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  @doc """
  Walks the path segments from the root. Returns `{:folder, entry | nil}`
  (nil is the root), `{:file, entry}`, or `:not_found`.
  """
  def resolve(_entries, []), do: {:folder, nil}

  def resolve(entries, segments) do
    walk(entries, nil, segments)
  end

  defp walk(entries, parent_id, [segment | rest]) do
    found =
      entries
      |> children(parent_id)
      |> Enum.find(fn e -> name(e) == segment end)

    case {found, rest} do
      {nil, _} -> :not_found
      {e, []} -> if folder?(e), do: {:folder, e}, else: {:file, e}
      {e, _} -> if folder?(e), do: walk(entries, e.id, rest), else: :not_found
    end
  end

  @doc "Creates the folder at the path. The errors follow the RFC 4918 semantics."
  def mkcol(user_id, entries, segments) do
    {parents, [leaf]} = Enum.split(segments, -1)

    case resolve(entries, parents) do
      {:folder, parent} ->
        parent_id = parent && parent.id

        if Enum.any?(children(entries, parent_id), &(name(&1) == leaf)) do
          # The name already exists: MKCOL must not overwrite.
          {:error, :exists}
        else
          Data.create_entry(user_id, %{
            kind: "file",
            source: @source,
            title: leaf,
            data: %{"filename" => leaf, "is_folder" => true, "parent_id" => parent_id}
          })
        end

      # An intermediate collection is missing.
      _ ->
        {:error, :conflict}
    end
  end

  @doc """
  Stores the uploaded temp file and creates (201) or replaces (204) the
  entry at the path. Returns `{:ok, :created | :updated, entry}`.
  """
  def put_file(user_id, entries, segments, tmp_path) do
    {parents, [leaf]} = Enum.split(segments, -1)

    with {:folder, parent} <- resolve(entries, parents) do
      parent_id = parent && parent.id
      existing = entries |> children(parent_id) |> Enum.find(&(name(&1) == leaf))

      cond do
        existing && folder?(existing) ->
          {:error, :conflict}

        true ->
          store_and_record(user_id, leaf, parent_id, existing, tmp_path)
      end
    else
      _ -> {:error, :conflict}
    end
  end

  defp store_and_record(user_id, leaf, parent_id, existing, tmp_path) do
    size =
      case File.stat(tmp_path) do
        {:ok, %{size: s}} -> s
        _ -> 0
      end

    with {:ok, relative, _absolute} <-
           Storage.store_app_file(user_id, "files", tmp_path, ext: Path.extname(leaf)) do
      data = %{
        "filename" => leaf,
        "path" => Storage.public_url(relative),
        "size" => size,
        "mime_type" => MIME.from_path(leaf),
        "parent_id" => parent_id
      }

      case existing do
        nil ->
          attrs = %{
            kind: "file",
            source: @source,
            title: leaf,
            occurred_at: DateTime.truncate(DateTime.utc_now(), :second),
            data: data
          }

          with {:ok, entry} <- Data.create_entry(user_id, attrs), do: {:ok, :created, entry}

        entry ->
          # Replace: the new blob comes first, then drop the old blob.
          old_path = entry.data["path"]

          with {:ok, updated} <-
                 Data.update_entry(user_id, entry.id, %{
                   title: leaf,
                   data: Map.merge(entry.data, data)
                 }) do
            if is_binary(old_path) and old_path != "",
              do: Storage.delete_public_file(user_id, old_path)

            {:ok, :updated, updated}
          end
      end
    end
  end

  @doc "Deletes a file, or a folder and everything below it."
  def delete(user_id, entries, entry) do
    for child <- children(entries, entry.id), do: delete(user_id, entries, child)
    Data.delete_entry(user_id, entry.id)
    :ok
  end
end
