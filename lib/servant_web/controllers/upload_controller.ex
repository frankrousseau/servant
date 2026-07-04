defmodule ServantWeb.UploadController do
  use ServantWeb, :controller

  @max_size 50_000_000

  @allowed_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "video/mp4" => ".mp4",
    "video/quicktime" => ".mov",
    "video/webm" => ".webm",
    "application/pdf" => ".pdf",
    "text/plain" => ".txt",
    "text/csv" => ".csv",
    "application/json" => ".json",
    "application/zip" => ".zip",
    "application/octet-stream" => ""
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
            |> json(%{error: "File too large (max 50MB)"})
        end

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "A file is required"})
    end
  end

  defp validate_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_size -> {:error, :too_large}
      {:ok, _} -> :ok
      _ -> {:error, "Failed to read uploaded file"}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

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

  defp maybe_add_photo_thumbnail(response, "photos", "image/" <> _, relative, absolute) do
    case Servant.Media.Thumbnail.create_for_storage(relative, absolute) do
      {:ok, thumb_url, _} -> Map.put(response, :thumb_path, thumb_url)
      :error -> response
    end
  end

  defp maybe_add_photo_thumbnail(response, _app_id, _content_type, _relative, _absolute),
    do: response
end
