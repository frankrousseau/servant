defmodule ServantWeb.UploadController do
  use ServantWeb, :controller

  @upload_dir "app_files"
  @max_size 50_000_000

  @allowed_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "application/pdf" => ".pdf",
    "text/plain" => ".txt",
    "text/csv" => ".csv",
    "application/json" => ".json",
    "application/zip" => ".zip",
    "application/octet-stream" => ""
  }

  def create(conn, %{"file" => %Plug.Upload{path: tmp_path, content_type: content_type, filename: original_name}}) do
    user_id = conn.assigns.current_user.id

    case File.stat(tmp_path) do
      {:ok, %{size: size}} when size > @max_size ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "File too large (max 50MB)"})

      {:ok, %{size: size}} ->
        ext = Map.get(@allowed_types, content_type, Path.extname(original_name))
        uuid = Ecto.UUID.generate()
        relative_dir = "#{@upload_dir}/#{user_id}"
        filename = "#{uuid}#{ext}"
        relative_path = "#{relative_dir}/#{filename}"

        abs_dir = Path.join([:code.priv_dir(:servant), "uploads", relative_dir])
        abs_path = Path.join(abs_dir, filename)

        File.mkdir_p!(abs_dir)
        File.cp!(tmp_path, abs_path)

        # Extract EXIF metadata for images
        exif =
          if String.starts_with?(content_type, "image/") do
            Servant.Media.Exif.extract(abs_path)
          else
            %{}
          end

        response = %{
          path: "/uploads/#{relative_path}",
          filename: original_name,
          size: size,
          mime_type: content_type
        }

        response =
          case exif do
            %{date_taken: %DateTime{} = dt} ->
              Map.put(response, :date_taken, DateTime.to_iso8601(dt))

            _ ->
              response
          end

        response =
          case exif do
            %{gps: %{latitude: lat, longitude: lon}} when not is_nil(lat) ->
              Map.merge(response, %{latitude: lat, longitude: lon})

            _ ->
              response
          end

        response =
          case exif do
            %{camera_make: make, camera_model: model} when not is_nil(make) ->
              Map.put(response, :camera, String.trim("#{make} #{model || ""}"))

            _ ->
              response
          end

        json(conn, response)

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to read uploaded file"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "A file is required"})
  end
end
