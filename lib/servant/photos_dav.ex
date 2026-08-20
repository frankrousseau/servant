defmodule Servant.PhotosDav do
  @moduledoc """
  WebDAV view over the Photos app: a virtual tree derived from `photo`
  entries where folders are album names (`data.album`). Nested client
  folders map to slash-joined albums (`Camera/2026-08`), so albums have
  no entity of their own: MKCOL answers 201 without persisting anything,
  and an unknown extensionless path resolves as an empty album so the
  MKCOL then PROPFIND then PUT dance of sync clients keeps working.

  PUT runs the whole photo pipeline server side (store, EXIF, video
  date, thumbnails, entry creation), the part the SPA upload queue does
  in the browser. A re-PUT of the same album/filename pair updates the
  existing entry in place, preserving tags and face data.
  """

  alias Servant.Data
  alias Servant.Media.Exif
  alias Servant.Media.Thumbnail
  alias Servant.Media.VideoMeta
  alias Servant.Storage

  @source "webdav"

  @spec photos(String.t()) :: [Data.Entry.t()]
  def photos(user_id), do: Data.all_entries(user_id, %{"kind" => "photo"})

  def filename(entry) do
    case entry.data["filename"] do
      name when is_binary(name) and name != "" -> name
      _ -> entry.title || "unnamed"
    end
  end

  def album(entry) do
    case entry.data["album"] do
      album when is_binary(album) and album != "" -> album
      _ -> nil
    end
  end

  @doc """
  Resolves path segments against the virtual tree. Returns
  `{:file, entry}`, `{:folder, prefix}` (nil prefix is the root), or
  `:not_found`. An unknown extensionless path counts as an empty album.
  """
  def resolve(_photos, []), do: {:folder, nil}

  def resolve(photos, segments) do
    {parents, [leaf]} = Enum.split(segments, -1)
    prefix = join_album(parents)

    found = photos |> photos_in(prefix) |> Enum.find(&(filename(&1) == leaf))
    full = join_album(segments)

    cond do
      found != nil -> {:file, found}
      album_exists?(photos, full) -> {:folder, full}
      Path.extname(leaf) == "" -> {:folder, full}
      true -> :not_found
    end
  end

  @doc "Photos whose album is exactly the prefix (nil at the root)."
  def photos_in(photos, prefix) do
    Enum.filter(photos, &(album(&1) == prefix))
  end

  @doc "Next-level folder names under the prefix, from distinct albums."
  def child_folders(photos, prefix) do
    photos
    |> Enum.map(&album/1)
    |> Enum.filter(&under?(&1, prefix))
    |> Enum.map(&next_segment(&1, prefix))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "RFC 4918-shaped MKCOL outcome; albums are virtual, nothing persists."
  def mkcol_status(photos, segments) do
    if album_exists?(photos, join_album(segments)), do: :exists, else: :created
  end

  @doc """
  Stores the uploaded temp file and creates (201) or replaces (204) the
  photo at the path. `opts[:mtime]` is the client-supplied modification
  time used when the media carries no capture date of its own.
  """
  def put_photo(user_id, photos, segments, tmp_path, opts \\ []) do
    {parents, [leaf]} = Enum.split(segments, -1)
    album = join_album(parents)
    mime = MIME.from_path(leaf)
    existing = photos |> photos_in(album) |> Enum.find(&(filename(&1) == leaf))

    size =
      case File.stat(tmp_path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    with {:ok, relative, absolute} <-
           Storage.store_app_file(user_id, "photos", tmp_path, ext: Path.extname(leaf)) do
      media = media_fields(mime, leaf, relative, absolute)

      data =
        Map.merge(
          %{
            "filename" => leaf,
            "path" => Storage.public_url(relative),
            "size" => size,
            "mime_type" => mime,
            "album" => album,
            "tags" => []
          },
          media
        )

      occurred_at = occurred_at(media, opts[:mtime])
      record(user_id, leaf, existing, data, occurred_at)
    end
  end

  defp record(user_id, leaf, nil, data, occurred_at) do
    attrs = %{
      kind: "photo",
      source: @source,
      title: leaf,
      occurred_at: occurred_at,
      data: data
    }

    with {:ok, entry} <- Data.create_entry(user_id, attrs), do: {:ok, :created, entry}
  end

  defp record(user_id, leaf, existing, data, occurred_at) do
    # Replace: new blob first, then drop the old one and its derivatives.
    old_paths =
      for key <- ["path", "thumb_path", "display_path"],
          path = existing.data[key],
          is_binary(path) and path != "",
          do: path

    # Merge over the old data so tags and face annotations survive; stale
    # derivative keys must not (the new blob may have no thumbnail).
    merged =
      existing.data
      |> Map.drop(["thumb_path", "display_path"])
      |> Map.merge(data)
      |> Map.put("tags", existing.data["tags"] || [])

    with {:ok, updated} <-
           Data.update_entry(user_id, existing.id, %{
             title: leaf,
             occurred_at: occurred_at,
             data: merged
           }) do
      for path <- old_paths, do: Storage.delete_public_file(user_id, path)
      {:ok, :updated, updated}
    end
  end

  @doc "Deletes a photo, or every photo in an album and its sub-albums."
  def delete(user_id, _photos, {:file, entry}) do
    Data.delete_entry(user_id, entry.id)
    :ok
  end

  def delete(user_id, photos, {:folder, prefix}) do
    for entry <- photos, album(entry) == prefix or under?(album(entry), prefix) do
      Data.delete_entry(user_id, entry.id)
    end

    :ok
  end

  # ----- pipeline helpers -----

  defp media_fields(mime, leaf, relative, absolute) do
    cond do
      String.starts_with?(mime, "image/") or heic?(leaf) ->
        exif = if String.starts_with?(mime, "image/"), do: Exif.extract(absolute), else: %{}
        Map.merge(exif_fields(exif), thumbnail_fields(relative, absolute))

      String.starts_with?(mime, "video/") ->
        case VideoMeta.creation_date(absolute) do
          {:ok, dt} -> %{"date_taken" => DateTime.to_iso8601(dt)}
          :error -> %{}
        end

      true ->
        %{}
    end
  end

  defp exif_fields(exif) do
    fields = %{}

    fields =
      case exif do
        %{date_taken: %DateTime{} = dt} -> Map.put(fields, "date_taken", DateTime.to_iso8601(dt))
        _ -> fields
      end

    fields =
      case exif do
        %{gps: %{latitude: lat, longitude: lon}} when is_number(lat) and is_number(lon) ->
          fields |> Map.put("latitude", lat) |> Map.put("longitude", lon)

        _ ->
          fields
      end

    case exif do
      %{camera_make: make, camera_model: model} when is_binary(make) ->
        Map.put(fields, "camera", String.trim("#{make} #{model || ""}"))

      _ ->
        fields
    end
  end

  defp thumbnail_fields(relative, absolute) do
    thumb =
      case Thumbnail.create_for_storage(relative, absolute) do
        {:ok, thumb_url, _} -> %{"thumb_path" => thumb_url}
        :error -> %{}
      end

    display =
      case Thumbnail.create_display_for_storage(relative, absolute) do
        {:ok, display_url, _} -> %{"display_path" => display_url}
        :error -> %{}
      end

    Map.merge(thumb, display)
  end

  defp occurred_at(media, mtime) do
    parsed =
      with date when is_binary(date) <- media["date_taken"],
           {:ok, dt, _offset} <- DateTime.from_iso8601(date) do
        dt
      else
        _ -> nil
      end

    DateTime.truncate(parsed || mtime || DateTime.utc_now(), :second)
  end

  defp heic?(name), do: String.ends_with?(String.downcase(name), [".heic", ".heif"])

  defp join_album([]), do: nil
  defp join_album(segments), do: Enum.join(segments, "/")

  defp album_exists?(photos, prefix) do
    Enum.any?(photos, fn entry ->
      album = album(entry)
      album == prefix or under?(album, prefix)
    end)
  end

  defp under?(nil, _prefix), do: false
  defp under?(_album, nil), do: true
  defp under?(album, prefix), do: String.starts_with?(album, prefix <> "/")

  defp next_segment(album, nil), do: album |> String.split("/") |> hd()

  defp next_segment(album, prefix) do
    album
    |> String.replace_prefix(prefix <> "/", "")
    |> String.split("/")
    |> hd()
  end
end
