defmodule Servant.Media.VideoMetaTest do
  use ExUnit.Case, async: true

  alias Servant.Media.VideoMeta

  # Seconds between the QuickTime epoch (1904-01-01) and the Unix epoch.
  @qt_epoch_offset 2_082_844_800

  defp box(type, content), do: <<byte_size(content) + 8::32, type::binary, content::binary>>

  defp write_tmp(binary) do
    path = Path.join(System.tmp_dir!(), "vmeta_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, binary)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "reads the creation date from a v0 mvhd box" do
    dt = ~U[2020-06-15 12:00:00Z]
    qt_time = DateTime.to_unix(dt) + @qt_epoch_offset

    mvhd = box("mvhd", <<0, 0, 0, 0, qt_time::32, 0::32, 1000::32, 0::32>>)
    ftyp = box("ftyp", <<"isom", 0::32>>)
    path = write_tmp(ftyp <> box("moov", mvhd))

    assert {:ok, ^dt} = VideoMeta.creation_date(path)
  end

  test "reads a v1 (64-bit) mvhd box" do
    dt = ~U[2026-01-02 03:04:05Z]
    qt_time = DateTime.to_unix(dt) + @qt_epoch_offset

    mvhd = box("mvhd", <<1, 0, 0, 0, qt_time::64>>)
    path = write_tmp(box("moov", mvhd))

    assert {:ok, ^dt} = VideoMeta.creation_date(path)
  end

  test ":error when the creation time is unset (0)" do
    mvhd = box("mvhd", <<0, 0, 0, 0, 0::32, 0::32, 1000::32, 0::32>>)
    path = write_tmp(box("moov", mvhd))

    assert :error = VideoMeta.creation_date(path)
  end

  test ":error on files without a moov box (e.g. webm/garbage)" do
    assert :error = VideoMeta.creation_date(write_tmp(<<"not a video at all">>))
  end

  test ":error on a missing file" do
    assert :error = VideoMeta.creation_date("/nonexistent/file.mp4")
  end
end
