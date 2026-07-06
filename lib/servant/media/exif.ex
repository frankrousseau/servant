defmodule Servant.Media.Exif do
  @moduledoc """
  Extracts EXIF metadata from JPEG images: date taken, GPS coordinates,
  camera info. Returns nil values gracefully when data is missing.
  """

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
        %{}
    end
  rescue
    _ -> %{}
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
