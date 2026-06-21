defmodule Servant.Media.Thumbnail do
  @moduledoc """
  Generates JPEG thumbnails for photo uploads using libvips (via Vix).
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Repo
  alias Servant.Storage
  alias Vix.Vips.{Image, Operation}

  @max_width 400
  @quality 80

  @doc """
  Creates a JPEG thumbnail at `dest_path` from the image at `source_path`.
  Returns `:ok` or `:error`.
  """
  def generate(source_path, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))

    with {:ok, thumb} <- Operation.thumbnail(source_path, @max_width, size: :VIPS_SIZE_DOWN),
         :ok <- Image.write_to_file(thumb, dest_path, Q: @quality, strip: true) do
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
  Generates missing thumbnails for photo entries and updates their `thumb_path`.
  Returns a list of `{:ok, entry_id}` or `{:error, entry_id, reason}` tuples.
  """
  def backfill_missing do
    Entry
    |> where([e], e.kind == "photo")
    |> Repo.all()
    |> Enum.filter(&missing_thumb?/1)
    |> Enum.map(&backfill_entry/1)
  end

  defp backfill_entry(%Entry{} = entry) do
    case create_for_public_path(entry.data["path"]) do
      {:ok, thumb_url, _} ->
        new_data = Map.put(entry.data, "thumb_path", thumb_url)

        case entry
             |> Entry.changeset(%{data: new_data})
             |> Repo.update() do
          {:ok, _} -> {:ok, entry.id}
          {:error, reason} -> {:error, entry.id, reason}
        end

      :error ->
        {:error, entry.id, :thumbnail_failed}
    end
  end

  defp missing_thumb?(%Entry{data: data}) when is_map(data) do
    path = Map.get(data, "path")
    thumb = Map.get(data, "thumb_path")

    is_binary(path) and path != "" and (not is_binary(thumb) or thumb == "")
  end

  defp missing_thumb?(_), do: false

  defp relative_from_public(public_path) do
    public_path
    |> String.trim()
    |> String.replace_prefix("/files/", "")
    |> String.replace_prefix("/uploads/", "")
  end
end
