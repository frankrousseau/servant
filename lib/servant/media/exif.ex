defmodule Servant.Media.Exif do
  @moduledoc """
  Extracts EXIF metadata from images: date taken, GPS coordinates,
  camera info. Returns nil values gracefully when data is missing.

  JPEG files go through `ExifParser`; anything else falls back to the
  `exif-*` header fields libvips exposes through Vix (libexif build),
  which covers HEIC photos coming from phones over WebDAV.
  """

  alias Vix.Vips.Image

  @doc """
  Extracts EXIF data from a file path.
  Returns a map with normalized fields, or an empty map if no EXIF found.
  """
  def extract(path) do
    case ExifParser.parse_jpeg_file(path) do
      {:ok, exif} ->
        %{
          date_taken: extract_date(exif),
          gps: extract_gps(exif),
          camera_make: get_in_exif(exif, [:ifd0, :make]),
          camera_model: get_in_exif(exif, [:ifd0, :model]),
          orientation: get_in_exif(exif, [:ifd0, :orientation]),
          width: get_in_exif(exif, [:exif, :pixel_x_dimension]),
          height: get_in_exif(exif, [:exif, :pixel_y_dimension])
        }

      {:error, _} ->
        extract_via_vips(path)
    end
  rescue
    _ -> %{}
  end

  # libvips renders each EXIF entry as "value (value, type, n components,
  # n bytes)"; strip the parenthesized suffix to get the value back.
  defp extract_via_vips(path) do
    with {:ok, img} <- Image.new_from_file(path),
         {:ok, fields} <- Image.header_field_names(img),
         true <- Enum.any?(fields, &String.starts_with?(&1, "exif-ifd")) do
      %{
        date_taken: parse_exif_date(vips_field(img, "exif-ifd2-DateTimeOriginal")),
        gps: vips_gps(img),
        camera_make: vips_field(img, "exif-ifd0-Make"),
        camera_model: vips_field(img, "exif-ifd0-Model"),
        orientation: vips_orientation(img),
        width: Image.width(img),
        height: Image.height(img)
      }
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp vips_field(img, name) do
    case Image.header_value(img, name) do
      {:ok, value} when is_binary(value) ->
        String.replace(value, ~r/ \([^)]*\)$/, "")

      _ ->
        nil
    end
  end

  defp vips_gps(img) do
    lat = vips_field(img, "exif-ifd3-GPSLatitude")
    lat_ref = vips_field(img, "exif-ifd3-GPSLatitudeRef")
    lon = vips_field(img, "exif-ifd3-GPSLongitude")
    lon_ref = vips_field(img, "exif-ifd3-GPSLongitudeRef")

    with [_ | _] = lat_dms <- parse_rationals(lat),
         [_ | _] = lon_dms <- parse_rationals(lon) do
      %{
        latitude: dms_to_decimal(lat_dms, lat_ref),
        longitude: dms_to_decimal(lon_dms, lon_ref)
      }
    else
      _ -> nil
    end
  end

  # "47/1 30/1 1234/100" -> [47.0, 30.0, 12.34]
  defp parse_rationals(nil), do: nil

  defp parse_rationals(value) do
    for part <- String.split(value, " ", trim: true),
        [n, d] <- [String.split(part, "/", parts: 2)],
        {num, ""} <- [Integer.parse(n)],
        {den, ""} <- [Integer.parse(d)],
        den > 0 do
      num / den
    end
  end

  defp vips_orientation(img) do
    case Image.header_value(img, "orientation") do
      {:ok, orientation} when is_integer(orientation) -> orientation
      _ -> nil
    end
  end

  defp extract_date(exif) do
    # Try multiple date fields in order of preference
    date_str =
      get_in_exif(exif, [:exif, :date_time_original]) ||
        get_in_exif(exif, [:exif, :date_time_digitized]) ||
        get_in_exif(exif, [:ifd0, :date_time])

    parse_exif_date(date_str)
  end

  defp extract_gps(exif) do
    gps = Map.get(exif, :gps, %{}) || %{}

    lat = Map.get(gps, :gps_latitude)
    lat_ref = Map.get(gps, :gps_latitude_ref)
    lon = Map.get(gps, :gps_longitude)
    lon_ref = Map.get(gps, :gps_longitude_ref)

    if lat && lon do
      %{
        latitude: dms_to_decimal(lat, lat_ref),
        longitude: dms_to_decimal(lon, lon_ref)
      }
    else
      nil
    end
  end

  # Convert [degrees, minutes, seconds] to decimal
  defp dms_to_decimal(dms, ref) when is_list(dms) and length(dms) == 3 do
    [d, m, s] = Enum.map(dms, &to_float/1)
    decimal = d + m / 60.0 + s / 3600.0

    case ref do
      r when r in ["S", "W"] -> -decimal
      _ -> decimal
    end
  end

  defp dms_to_decimal(val, ref) when is_number(val) do
    case ref do
      r when r in ["S", "W"] -> -val
      _ -> val
    end
  end

  defp dms_to_decimal(_, _), do: nil

  defp to_float(val) when is_integer(val), do: val / 1
  defp to_float(val) when is_float(val), do: val
  defp to_float({n, d}) when is_integer(n) and is_integer(d) and d > 0, do: n / d
  defp to_float(_), do: 0.0

  # Parse "2025:03:28 14:30:00" format
  defp parse_exif_date(nil), do: nil

  defp parse_exif_date(str) when is_binary(str) do
    case Regex.run(~r/^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/, str) do
      [_, y, mo, d, h, mi, s] ->
        case NaiveDateTime.new(
               String.to_integer(y),
               String.to_integer(mo),
               String.to_integer(d),
               String.to_integer(h),
               String.to_integer(mi),
               String.to_integer(s)
             ) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_exif_date(_), do: nil

  defp get_in_exif(exif, [key1, key2]) do
    case Map.get(exif, key1) do
      nil -> nil
      map when is_map(map) -> Map.get(map, key2)
      _ -> nil
    end
  end
end
