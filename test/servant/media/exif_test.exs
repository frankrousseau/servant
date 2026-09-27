defmodule Servant.Media.ExifTest do
  use ExUnit.Case, async: true

  alias Servant.Media.Exif
  alias Vix.Vips.{Image, MutableImage}

  # Minimal 1x1 JPEG, same fixture as the thumbnail tests.
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q=="
        )

  @exif_fields [
    {"exif-ifd0-Make", "Apple"},
    {"exif-ifd0-Model", "iPhone 15 Pro"},
    {"exif-ifd2-DateTimeOriginal", "2024:07:14 18:30:12"},
    {"exif-ifd3-GPSLatitude", "47/1 30/1 1234/100"},
    {"exif-ifd3-GPSLatitudeRef", "N"},
    {"exif-ifd3-GPSLongitude", "2/1 20/1 500/100"},
    {"exif-ifd3-GPSLongitudeRef", "E"}
  ]

  # Anything that is not a JPEG goes through the libvips header fallback: that
  # is the path HEIC photos from phones take (PNG here, since a libvips build
  # without HEIC support would make the test environment-dependent).
  test "extracts date, GPS and camera from a non-JPEG through the vips fallback" do
    tmp = System.tmp_dir!()
    png = Path.join(tmp, "exif-test-#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm(png) end)

    assert :ok = write_image_with_exif(png)

    exif = Exif.extract(png)

    assert exif.camera_make == "Apple"
    assert exif.camera_model == "iPhone 15 Pro"
    assert exif.date_taken == ~U[2024-07-14 18:30:12Z]
    assert_in_delta exif.gps.latitude, 47.5034, 0.001
    assert_in_delta exif.gps.longitude, 2.3347, 0.001
  end

  test "a file without EXIF yields an empty map" do
    tmp = System.tmp_dir!()
    jpg = Path.join(tmp, "exif-empty-#{System.unique_integer([:positive])}.jpg")
    on_exit(fn -> File.rm(jpg) end)
    File.write!(jpg, @jpeg)

    assert Exif.extract(jpg) == %{}
  end

  test "garbage bytes yield an empty map" do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "exif-garbage-#{System.unique_integer([:positive])}.heic")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "not an image at all")

    assert Exif.extract(path) == %{}
  end

  # JPEG goes through ExifParser (not the vips fallback). Regression: the EXIF
  # and GPS sub-IFDs are nested under ifd0, so reading them at the top level
  # silently dropped the date and the coordinates of every JPEG photo.
  test "extracts date, GPS and dimensions from a JPEG through ExifParser" do
    tmp = System.tmp_dir!()
    jpg = Path.join(tmp, "exif-jpeg-#{System.unique_integer([:positive])}.jpg")
    on_exit(fn -> File.rm(jpg) end)

    assert :ok = write_image_with_exif(jpg)

    exif = Exif.extract(jpg)

    assert exif.date_taken == ~U[2024-07-14 18:30:12Z]
    assert_in_delta exif.gps.latitude, 47.5034, 0.001
    assert_in_delta exif.gps.longitude, 2.3347, 0.001
    assert exif.camera_make == "Apple"
    assert exif.camera_model == "iPhone 15 Pro"
    assert exif.orientation == 1
    assert exif.width == 1
    assert exif.height == 1
  end

  test "southern and western coordinates come back negative" do
    tmp = System.tmp_dir!()
    jpg = Path.join(tmp, "exif-south-#{System.unique_integer([:positive])}.jpg")
    on_exit(fn -> File.rm(jpg) end)

    fields =
      Enum.map(@exif_fields, fn
        {"exif-ifd3-GPSLatitudeRef", _} -> {"exif-ifd3-GPSLatitudeRef", "S"}
        {"exif-ifd3-GPSLongitudeRef", _} -> {"exif-ifd3-GPSLongitudeRef", "W"}
        other -> other
      end)

    assert :ok = write_image_with_exif(jpg, fields)

    exif = Exif.extract(jpg)
    assert exif.gps.latitude < 0
    assert exif.gps.longitude < 0
  end

  # Tags the fixture through the exif-* mutable fields, then writes it to
  # `path` in whatever format its extension asks for.
  # iPhone photos are HEIC, which the bundled libvips cannot decode: the Exif
  # item is read straight from the file. The fake HEIC wraps the TIFF block of
  # a tagged JPEG the way phones store it (item offset, "Exif\0\0", TIFF).
  test "extracts date, GPS and camera from an iPhone HEIC" do
    tmp = System.tmp_dir!()
    jpg = Path.join(tmp, "exif-src-heic-#{System.unique_integer([:positive])}.jpg")
    heic = Path.join(tmp, "exif-#{System.unique_integer([:positive])}.heic")
    on_exit(fn -> Enum.each([jpg, heic], &File.rm/1) end)

    assert :ok = write_image_with_exif(jpg)
    jpeg = File.read!(jpg)
    {start, _length} = :binary.match(jpeg, <<"Exif", 0, 0>>)
    exif_item = binary_part(jpeg, start, byte_size(jpeg) - start)

    File.write!(
      heic,
      <<24::32, "ftypheic", 0::32, "mif1heic">> <>
        :crypto.strong_rand_bytes(512) <> <<6::32>> <> exif_item
    )

    exif = Exif.extract(heic)

    assert exif.date_taken == ~U[2024-07-14 18:30:12Z]
    assert_in_delta exif.gps.latitude, 47.5034, 0.001
    assert_in_delta exif.gps.longitude, 2.3347, 0.001
    assert exif.camera_make == "Apple"
    assert exif.camera_model == "iPhone 15 Pro"
  end

  defp write_image_with_exif(path, fields \\ @exif_fields) do
    source = Path.join(System.tmp_dir!(), "exif-src-#{System.unique_integer([:positive])}.jpg")
    File.write!(source, @jpeg)
    on_exit(fn -> File.rm(source) end)

    with {:ok, img} <- Image.new_from_file(source),
         {:ok, tagged} <- Image.mutate(img, &set_fields(&1, fields)) do
      Image.write_to_file(tagged, path)
    end
  end

  defp set_fields(mut, fields) do
    results =
      for {field, value} <- fields do
        MutableImage.set(mut, field, :VipsRefString, value)
      end

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, results}
  end
end
