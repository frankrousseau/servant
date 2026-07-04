defmodule ServantWeb.UploadController do
  use ServantWeb, :controller

  @default_max_size 1_000_000_000

  defp max_size, do: Application.get_env(:servant, :max_upload_size, @default_max_size)

  @allowed_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "image/heic" => ".heic",
    "image/heif" => ".heif",
    "video/mp4" => ".mp4",
    "video/quicktime" => ".mov",
    "video/webm" => ".webm",
    "application/pdf" => ".pdf",
    "text/plain" => ".txt",
    "text/csv" => ".csv",
    "application/json" => ".json",
    "application/zip" => ".zip"
  }

  def create(conn, params) do
    case params do
      %{
        "file" => %Plug.Upload{
          path: tmp_path,
          content_type: content_type,
          filename: original_name
        }
      } ->
        user_id = conn.assigns.current_user.id
        app_id = Map.get(params, "app", "files")

        with :ok <- validate_size(tmp_path),
             ext <- extension(content_type, original_name),
             {:ok, relative, absolute} <-
               Servant.Storage.store_app_file(user_id, app_id, tmp_path, ext: ext) do
          exif =
            if String.starts_with?(content_type, "image/") do
              Servant.Media.Exif.extract(absolute)
            else
              %{}
            end

          response = %{
            path: Servant.Storage.public_url(relative),
            filename: original_name,
            size: file_size(tmp_path),
            mime_type: content_type,
            app: app_id
          }

          response =
            response
            |> apply_exif(exif)
            |> maybe_video_date(content_type, absolute)
            |> maybe_add_photo_thumbnail(app_id, content_type, relative, absolute)

          json(conn, response)
        else
          {:error, message} when is_binary(message) ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: message})

          {:error, :too_large} ->
            conn
            |> put_status(:request_entity_too_large)
            |> json(%{error: "File too large (max 1GB)"})
        end

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "A file is required"})
    end
  end

  defp validate_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> if size > max_size(), do: {:error, :too_large}, else: :ok
      _ -> {:error, "Failed to read uploaded file"}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # Browsers often send unknown formats (e.g. .heic on Linux) as
  # application/octet-stream: fall back to the original file's extension.
  defp extension("application/octet-stream", original_name), do: Path.extname(original_name)

  defp extension(content_type, original_name) do
    Map.get(@allowed_types, content_type, Path.extname(original_name))
  end

  defp apply_exif(response, exif) do
    response
    |> put_exif_field(:date_taken, exif, fn
      %{date_taken: %DateTime{} = dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end)
    |> put_exif_field(:latitude, exif, fn
      %{gps: %{latitude: lat}} when not is_nil(lat) -> lat
      _ -> nil
    end)
    |> put_exif_field(:longitude, exif, fn
      %{gps: %{longitude: lon}} when not is_nil(lon) -> lon
      _ -> nil
    end)
    |> put_exif_field(:camera, exif, fn
      %{camera_make: make, camera_model: model} when not is_nil(make) ->
        String.trim("#{make} #{model || ""}")

      _ ->
        nil
    end)
  end

  defp put_exif_field(response, key, exif, fun) do
    case fun.(exif) do
      nil -> response
      value -> Map.put(response, key, value)
    end
  end

  # MP4/MOV carry their recording date in the moov/mvhd box; expose it the
  # same way as photo EXIF so entries sort by capture date.
  defp maybe_video_date(response, "video/" <> _, absolute) do
    case Servant.Media.VideoMeta.creation_date(absolute) do
      {:ok, dt} -> Map.put_new(response, :date_taken, DateTime.to_iso8601(dt))
      :error -> response
    end
  end

  defp maybe_video_date(response, _content_type, _absolute), do: response

  defp maybe_add_photo_thumbnail(response, "photos", content_type, relative, absolute) do
    if String.starts_with?(content_type, "image/") or heic?(relative) do
      response =
        case Servant.Media.Thumbnail.create_for_storage(relative, absolute) do
          {:ok, thumb_url, _} -> Map.put(response, :thumb_path, thumb_url)
          :error -> response
        end

      # Fast 1920px JPEG for the viewer; the original stays archived and is
      # loadable on demand.
      case Servant.Media.Thumbnail.create_display_for_storage(relative, absolute) do
        {:ok, display_url, _} -> Map.put(response, :display_path, display_url)
        :error -> response
      end
    else
      response
    end
  end

  defp maybe_add_photo_thumbnail(response, _app_id, _content_type, _relative, _absolute),
    do: response

  defp heic?(path), do: String.ends_with?(String.downcase(path), [".heic", ".heif"])
end
