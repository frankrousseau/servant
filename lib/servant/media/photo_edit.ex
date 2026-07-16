defmodule Servant.Media.PhotoEdit do
  @moduledoc """
  In-place edits on stored photos. Rotation re-encodes the original
  (libvips has no lossless JPEG transform) into a new file, regenerates the
  thumbnail and display JPEG, then deletes the old files. A fresh filename
  sidesteps both the libvips operation cache (which returns the pre-rotation
  image when the same path is reloaded in-process) and stale browser caches.
  """

  alias Servant.Data
  alias Servant.Data.Entry
  alias Servant.Media.Thumbnail
  alias Servant.Storage
  alias Vix.Vips.{Image, Operation}

  @angles %{90 => :VIPS_ANGLE_D90, 180 => :VIPS_ANGLE_D180, 270 => :VIPS_ANGLE_D270}
  @jpeg_quality 92

  @doc """
  Rotates the photo's original file clockwise by `angle` degrees, refreshes
  its derived thumbnail/display JPEGs and updates the entry (broadcasts the
  change). Returns `{:ok, entry}` or `{:error, message}`.
  """
  def rotate(%Entry{} = entry, angle) when is_map_key(@angles, angle) do
    old_relative = Storage.relative_from_public(entry.data["path"] || "")

    with {:ok, old_absolute} <- resolve(entry.user_id, old_relative),
         {:ok, relative, absolute} <-
           rotate_to_new_file(entry.user_id, old_absolute, Map.fetch!(@angles, angle)) do
      data =
        entry.data
        |> Map.put("path", Storage.public_url(relative))
        |> put_derived("thumb_path", Thumbnail.create_for_storage(relative, absolute))
        |> put_derived("display_path", Thumbnail.create_display_for_storage(relative, absolute))

      case Data.update_entry(entry.user_id, entry.id, %{"data" => data}) do
        {:ok, updated} ->
          remove_old_files(entry)
          {:ok, updated}

        error ->
          # The entry still points at the old files; drop the freshly written
          # rotated original and its derivatives so they don't leak on disk.
          remove_files(entry.user_id, data)
          error
      end
    end
  end

  def rotate(%Entry{}, _angle), do: {:error, "angle must be 90, 180 or 270"}

  defp resolve(user_id, relative) do
    case Storage.resolve_owned_path(user_id, relative) do
      {:ok, absolute} -> {:ok, absolute}
      :error -> {:error, "photo file not found"}
    end
  end

  # Bake any EXIF orientation into the pixels first (autorot also drops the
  # orientation tag, so viewers won't rotate a second time), then rotate into
  # a fresh file: a failed encode never touches the original.
  defp rotate_to_new_file(user_id, old_absolute, vips_angle) do
    ext = old_absolute |> Path.extname() |> String.downcase()
    relative = Path.join([user_id, "apps", "photos", Ecto.UUID.generate() <> ext])
    absolute = Storage.join_files([relative])
    File.mkdir_p!(Path.dirname(absolute))

    with {:ok, img} <- Image.new_from_file(old_absolute),
         {:ok, {img, _flags}} <- Operation.autorot(img),
         {:ok, img} <- Operation.rot(img, vips_angle),
         :ok <- Image.write_to_file(img, absolute, save_opts(ext)) do
      {:ok, relative, absolute}
    else
      _ ->
        File.rm(absolute)
        {:error, "rotation failed (unsupported image format?)"}
    end
  end

  defp save_opts(ext) when ext in [".jpg", ".jpeg"], do: [Q: @jpeg_quality]
  defp save_opts(_ext), do: []

  # A failed regeneration drops the key: the frontend falls back to the
  # original path rather than pointing at a missing file.
  defp put_derived(data, key, {:ok, url, _relative}), do: Map.put(data, key, url)
  defp put_derived(data, key, :error), do: Map.delete(data, key)

  defp remove_old_files(%Entry{user_id: user_id, data: data}), do: remove_files(user_id, data)

  defp remove_files(user_id, data) do
    for key <- ["path", "thumb_path", "display_path"],
        url = data[key],
        is_binary(url) do
      Storage.delete_public_file(user_id, url)
    end
  end
end
