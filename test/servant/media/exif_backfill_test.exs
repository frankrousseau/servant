defmodule Servant.Media.ExifBackfillTest do
  # This module calls System.put_env on the storage roots. Keep it serial.
  use Servant.DataCase, async: false

  import Servant.Fixtures

  alias Servant.Media.Exif
  alias Servant.Repo
  alias Servant.Storage

  setup do
    base = Path.join(System.tmp_dir!(), "servant-exif-#{System.unique_integer([:positive])}")
    System.put_env("FILES_DIR", Path.join(base, "files"))
    System.put_env("TMP_DIR", Path.join(base, "tmp"))

    on_exit(fn ->
      System.delete_env("FILES_DIR")
      System.delete_env("TMP_DIR")
      File.rm_rf(base)
    end)

    %{user: user_fixture()}
  end

  # A HEIC with an Exif item that carries a date and a position. The TIFF block
  # is built by hand: big-endian, IFD0 -> EXIF IFD date, IFD0 -> GPS IFD.
  defp heic_with_exif do
    date = "2024:07:14 18:30:12" <> <<0>>
    # The offsets are from the start of the TIFF header.
    ifd0 = 8
    exif_ifd = ifd0 + 2 + 2 * 12 + 4
    date_at = exif_ifd + 2 + 12 + 4
    gps_ifd = date_at + byte_size(date)
    rationals_at = gps_ifd + 2 + 4 * 12 + 4

    tiff =
      <<"MM", 42::16, ifd0::32>> <>
        <<2::16, 0x8769::16, 4::16, 1::32, exif_ifd::32, 0x8825::16, 4::16, 1::32, gps_ifd::32,
          0::32>> <>
        <<1::16, 0x9003::16, 2::16, byte_size(date)::32, date_at::32, 0::32>> <>
        date <>
        <<4::16, 1::16, 2::16, 2::32, "N", 0, 0, 0, 2::16, 5::16, 3::32, rationals_at::32, 3::16,
          2::16, 2::32, "E", 0, 0, 0, 4::16, 5::16, 3::32, rationals_at + 24::32, 0::32>> <>
        <<47::32, 1::32, 30::32, 1::32, 1234::32, 100::32>> <>
        <<2::32, 1::32, 20::32, 1::32, 500::32, 100::32>>

    <<24::32, "ftypheic", 0::32, "mif1heic">> <> <<6::32, "Exif", 0, 0>> <> tiff
  end

  defp photo(user, data) do
    tmp = Path.join(System.tmp_dir!(), "exif-#{System.unique_integer([:positive])}.heic")
    File.write!(tmp, heic_with_exif())
    {:ok, relative, _absolute} = Storage.store_app_file(user.id, "photos", tmp, ext: ".heic")
    File.rm(tmp)

    entry_fixture(user.id, %{
      "kind" => "photo",
      "source" => "photos",
      "title" => "IMG_0001.HEIC",
      "data" => Map.put(data, "path", Storage.public_url(relative))
    })
  end

  test "fills date and location of HEIC photos imported without them", %{user: user} do
    bare = photo(user, %{"mime_type" => "image/heic"})
    dated = photo(user, %{"mime_type" => "image/heic", "date_taken" => "2020-01-01T00:00:00Z"})

    assert {1, 1} = Exif.backfill_missing(user.id)

    data = Repo.reload!(bare).data
    assert data["date_taken"] == "2024-07-14T18:30:12Z"
    assert_in_delta data["latitude"], 47.5034, 0.001
    assert_in_delta data["longitude"], 2.3347, 0.001

    # The backfill does not change a photo that already has a date.
    assert Repo.reload!(dated).data["date_taken"] == "2020-01-01T00:00:00Z"
  end
end
