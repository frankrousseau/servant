defmodule Servant.Media.Thumbnail do
  @moduledoc """
  Generates JPEG thumbnails for photo uploads with libvips (through Vix).
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Repo
  alias Servant.Storage
  alias Vix.Vips.{Image, Operation}

  @max_width 400
  @quality 80
  @display_max_width 1920
  @display_quality 85

  @doc """
  Creates a JPEG at `dest_path` from the image at `source_path`, downscaled
  to at most `max_width`. Returns `:ok` or `:error`.
  """
  def generate(source_path, dest_path, max_width \\ @max_width, quality \\ @quality) do
    File.mkdir_p!(Path.dirname(dest_path))

    with {:ok, thumb} <- Operation.thumbnail(source_path, max_width, size: :VIPS_SIZE_DOWN),
         :ok <- Image.write_to_file(thumb, dest_path, Q: quality, strip: true) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Generates a thumbnail for a stored file. Returns `{:ok, public_url, relative}` or `:error`.
  """
  def create_for_storage(relative, absolute) do
    thumb_relative = Storage.thumb_relative(relative)
    thumb_absolute = Storage.join_files([thumb_relative])

    result =
      if File.regular?(thumb_absolute) do
        :ok
      else
        generate(absolute, thumb_absolute)
      end

    case result do
      :ok -> {:ok, Storage.public_url(thumb_relative), thumb_relative}
      :error -> :error
    end
  end

  @doc """
  Generates a full-size display JPEG for the formats that browsers cannot
  render (for example HEIC). Returns `{:ok, public_url, relative}` or `:error`.
  """
  def create_display_for_storage(relative, absolute) do
    display_relative = Storage.display_relative(relative)
    display_absolute = Storage.join_files([display_relative])

    result =
      if File.regular?(display_absolute) do
        :ok
      else
        generate(absolute, display_absolute, @display_max_width, @display_quality)
      end

    case result do
      :ok -> {:ok, Storage.public_url(display_relative), display_relative}
      :error -> :error
    end
  end

  @doc """
  Generates a thumbnail from a public file URL (`/files/…` or legacy `/uploads/…`).
  """
  def create_for_public_path(public_path) when is_binary(public_path) do
    public_path
    |> relative_from_public()
    |> case do
      relative ->
        case Storage.resolve_public_path(relative) do
          {:ok, absolute} -> create_for_storage(relative, absolute)
          :error -> :error
        end
    end
  end

  def create_for_public_path(_), do: :error

  @doc """
  Generates a display JPEG from a public file URL (`/files/…` or legacy `/uploads/…`).
  """
  def create_display_for_public_path(public_path) when is_binary(public_path) do
    relative = relative_from_public(public_path)

    case Storage.resolve_public_path(relative) do
      {:ok, absolute} -> create_display_for_storage(relative, absolute)
      :error -> :error
    end
  end

  def create_display_for_public_path(_), do: :error

  @doc """
  Generates the missing thumbnails and display JPEGs for photo entries and
  updates their `thumb_path` / `display_path`. Pass a `user_id` to scope
  the run to one user (the API endpoint). Pass nil for all users (release task).
  Returns a list of `{:ok, entry_id}` or `{:error, entry_id, reason}` tuples.
  """
  @backfill_batch_size 100

  def backfill_missing(user_id \\ nil) do
    Entry
    |> where([e], e.kind == "photo")
    |> then(fn q -> if user_id, do: where(q, [e], e.user_id == ^user_id), else: q end)
    |> stream_in_batches(@backfill_batch_size)
    |> Stream.filter(&needs_media?/1)
    |> Stream.map(&backfill_entry/1)
    |> Enum.to_list()
  end

  # Keyset-paginate by id, so that the memory never holds every photo entry at
  # the same time. Each batch is its own query. As a result, the `Repo.update`
  # for each entry in `backfill_entry/1` runs between fetches (no open cursor,
  # SQLite-friendly).
  defp stream_in_batches(query, batch_size) do
    Stream.resource(
      fn -> nil end,
      fn last_id ->
        batch =
          query
          |> order_by([e], asc: e.id)
          |> limit(^batch_size)
          |> then(fn q -> if last_id, do: where(q, [e], e.id > ^last_id), else: q end)
          |> Repo.all()

        case batch do
          [] -> {:halt, last_id}
          rows -> {rows, List.last(rows).id}
        end
      end,
      fn _ -> :ok end
    )
  end

  defp backfill_entry(%Entry{} = entry) do
    path = entry.data["path"]

    updates =
      %{}
      |> maybe_generate(entry.data, "thumb_path", &create_for_public_path/1, path)
      |> maybe_generate(entry.data, "display_path", &create_display_for_public_path/1, path)

    cond do
      updates == %{} ->
        {:error, entry.id, :thumbnail_failed}

      true ->
        case entry
             |> Entry.changeset(%{data: Map.merge(entry.data, updates)})
             |> Repo.update() do
          {:ok, _} -> {:ok, entry.id}
          {:error, reason} -> {:error, entry.id, reason}
        end
    end
  end

  defp maybe_generate(updates, data, key, generator, path) do
    if blank?(Map.get(data, key)) do
      case generator.(path) do
        {:ok, url, _} -> Map.put(updates, key, url)
        :error -> updates
      end
    else
      updates
    end
  end

  defp needs_media?(%Entry{data: data}) when is_map(data) do
    path = Map.get(data, "path")

    is_binary(path) and path != "" and
      (blank?(Map.get(data, "thumb_path")) or blank?(Map.get(data, "display_path")))
  end

  defp needs_media?(_), do: false

  defp blank?(value), do: not is_binary(value) or value == ""

  defp relative_from_public(public_path), do: Storage.relative_from_public(public_path)
end
