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

  test "extracts date, GPS and camera from a HEIC through the vips fallback" do
    tmp = System.tmp_dir!()
    heic = Path.join(tmp, "exif-test-#{System.unique_integer([:positive])}.heic")
    on_exit(fn -> File.rm(heic) end)

    case write_heic_with_exif(heic) do
      :ok ->
        exif = Exif.extract(heic)

        assert exif.camera_make == "Apple"
        assert exif.camera_model == "iPhone 15 Pro"
        assert exif.date_taken == ~U[2024-07-14 18:30:12Z]
        assert_in_delta exif.gps.latitude, 47.5034, 0.001
        assert_in_delta exif.gps.longitude, 2.3347, 0.001

      :skip ->
        IO.puts("Skipping HEIC EXIF test: libvips lacks HEIC or EXIF support here")
    end
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

  # Tags a JPEG via the exif-* mutable fields (jpegsave materializes the
  # EXIF block), then converts it to HEIC; both steps need optional
  # libvips features, so any failure skips rather than fails.
  defp write_heic_with_exif(heic) do
    tmp = System.tmp_dir!()
    jpg = Path.join(tmp, "exif-src-#{System.unique_integer([:positive])}.jpg")
    File.write!(jpg, @jpeg)

    try do
      with {:ok, img} <- Image.new_from_file(jpg),
           {:ok, tagged} <- Image.mutate(img, &set_exif_fields/1),
           :ok <- Image.write_to_file(tagged, jpg),
           {:ok, reloaded} <- Image.new_from_file(jpg),
           :ok <- Image.write_to_file(reloaded, heic) do
        :ok
      else
        _ -> :skip
      end
    after
      File.rm(jpg)
    end
  end

  defp set_exif_fields(mut) do
    results =
      for {field, value} <- @exif_fields do
        MutableImage.set(mut, field, :VipsRefString, value)
      end

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, results}
  end
end
