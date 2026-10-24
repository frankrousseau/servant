defmodule Servant.Media.Exif do
  @moduledoc """
  Extracts EXIF metadata from images: date taken, GPS coordinates,
  camera info. Returns nil values without an error when data is missing.

  JPEG files and HEIC photos (iPhone) go through `ExifParser`. The HEIC
  Exif item is a plain TIFF block, found by its `Exif\\0\\0` marker. This is
  necessary because the libvips bundled with Vix has no HEIF loader. All
  other formats use the `exif-*` header fields that libvips exposes.
  """

  import Ecto.Query

  alias Servant.Data.Entry
  alias Servant.Repo
  alias Servant.Storage
  alias Vix.Vips.Image

  @doc """
  Extracts EXIF data from a file path.
  Returns a map with normalized fields, or an empty map if there is no EXIF data.
  """
  def extract(path) do
    case parse_exif(path) do
      {:ok, exif} ->
        %{
          date_taken: extract_date(exif),
          gps: extract_gps(exif),
          camera_make: get_in_exif(exif, [:ifd0, :make]),
          camera_model: get_in_exif(exif, [:ifd0, :model]),
          orientation: get_in_exif(exif, [:ifd0, :orientation]),
          width: get_in_exif(exif, [:ifd0, :exif, :pixel_x_dimension]),
          height: get_in_exif(exif, [:ifd0, :exif, :pixel_y_dimension])
        }

      {:error, _} ->
        extract_via_vips(path)
    end
  rescue
    _ -> %{}
  end

  @doc "Data fields of a photo entry (date_taken, latitude/longitude, camera) from `extract/1`."
  def entry_fields(exif) do
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

  @doc """
  Re-reads the EXIF of the photos stored without a date or a location (HEIC
  photos imported before the support of HEIC EXIF). Fills the fields that it
  finds and never overwrites a stored value. Returns `{updated, scanned}`.
  """
  def backfill_missing(user_id \\ nil) do
    photos =
      from(entry in Entry,
        where: entry.kind == "photo",
        where: fragment("json_extract(?, '$.date_taken') IS NULL", entry.data),
        where: fragment("json_extract(?, '$.latitude') IS NULL", entry.data)
      )
      |> then(fn query -> if user_id, do: where(query, user_id: ^user_id), else: query end)
      |> Repo.all()

    updated = Enum.count(photos, &backfill_entry/1)
    {updated, length(photos)}
  end

  defp backfill_entry(%Entry{data: %{"path" => "/files/" <> _ = public}} = entry) do
    with {:ok, absolute} <-
           Storage.resolve_owned_path(entry.user_id, Storage.relative_from_public(public)),
         fields when map_size(fields) > 0 <- entry_fields(extract(absolute)),
         {:ok, _entry} <-
           entry |> Entry.changeset(%{data: Map.merge(fields, entry.data)}) |> Repo.update() do
      true
    else
      _ -> false
    end
  end

  defp backfill_entry(_entry), do: false

  defp parse_exif(path) do
    with {:error, _} <- ExifParser.parse_jpeg_file(path) do
      parse_heic(path)
    end
  end

  # ponytail: a marker scan, not a walk of the ISOBMFF boxes (meta, iinf,
  # iloc). Phones write the Exif item as "Exif\0\0" + TIFF header. The TIFF
  # magic immediately after the marker rules out a stray match in pixel data.
  # Walk iloc if a camera stores the Exif item differently.
  @heic_max_bytes 64 * 1024 * 1024

  defp parse_heic(path) do
    with {:ok, <<_size::32, "ftyp", _rest::binary>> = data} <- read_head(path),
         {:ok, tiff} <- find_tiff(data) do
      ExifParser.parse_tiff_binary(tiff)
    else
      _ -> {:error, :no_exif}
    end
  end

  defp read_head(path), do: File.open(path, [:read], &IO.binread(&1, @heic_max_bytes))

  defp find_tiff(data) do
    [<<"Exif", 0, 0, "MM", 0, 42>>, <<"Exif", 0, 0, "II", 42, 0>>]
    |> Enum.find_value({:error, :no_exif}, fn marker ->
      case :binary.match(data, marker) do
        {offset, _length} -> {:ok, binary_part(data, offset + 6, byte_size(data) - offset - 6)}
        :nomatch -> nil
      end
    end)
  end

  # libvips renders each EXIF entry as "value (value, type, n components,
  # n bytes)". Strip the parenthesized suffix to get the value back.
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

  # ExifParser nests the EXIF and GPS sub-IFDs under ifd0. They never appear
  # at the top level. As a result, all these paths start at ifd0.
  defp extract_date(exif) do
    # Try multiple date fields in the order of preference.
    date_str =
      get_in_exif(exif, [:ifd0, :exif, :date_time_original]) ||
        get_in_exif(exif, [:ifd0, :exif, :date_time_digitized]) ||
        get_in_exif(exif, [:ifd0, :date_time])

    parse_exif_date(date_str)
  end

  defp extract_gps(exif) do
    gps = get_in_exif(exif, [:ifd0, :gps]) || %{}

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

  # Convert [degrees, minutes, seconds] to decimal.
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

  # Parse the "2025:03:28 14:30:00" format.
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

  defp get_in_exif(exif, path) do
    Enum.reduce_while(path, exif, fn key, value ->
      if is_map(value), do: {:cont, Map.get(value, key)}, else: {:halt, nil}
    end)
  end
end
