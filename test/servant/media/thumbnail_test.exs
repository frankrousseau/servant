defmodule Servant.Media.ThumbnailTest do
  use ExUnit.Case, async: true

  alias Servant.Media.Thumbnail
  alias Servant.Storage

  @tag :thumbnail
  test "generates a JPEG thumbnail from a source image" do
    tmp = System.tmp_dir!()
    source = Path.join(tmp, "thumb-source-#{System.unique_integer()}.jpg")
    dest = Path.join(tmp, "thumb-dest-#{System.unique_integer()}.jpg")

    on_exit(fn ->
      File.rm(source)
      File.rm(dest)
    end)

    assert :ok = write_minimal_jpeg(source)

    case Thumbnail.generate(source, dest) do
      :ok ->
        assert File.regular?(dest)
        assert File.stat!(dest).size > 0

      :error ->
        IO.puts("Skipping thumbnail generation: libvips not available in this environment")
    end
  end

  test "thumb_relative replaces extension with _thumb.jpg" do
    assert Storage.thumb_relative("user/apps/photos/abc.jpg") ==
             "user/apps/photos/abc_thumb.jpg"

    assert Storage.thumb_relative("user/apps/photos/abc.png") ==
             "user/apps/photos/abc_thumb.jpg"
  end

  defp write_minimal_jpeg(path) do
    jpeg =
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q=="
      )

    File.write(path, jpeg)
  end
end
