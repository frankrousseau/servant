defmodule Servant.Media.ThumbnailTest do
  use Servant.DataCase

  alias Servant.Data
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

    assert :ok = Thumbnail.generate(source, dest)
    assert File.stat!(dest).size > 0
  end

  test "thumb_relative replaces extension with _thumb.jpg" do
    assert Storage.thumb_relative("user/apps/photos/abc.jpg") ==
             "user/apps/photos/abc_thumb.jpg"

    assert Storage.thumb_relative("user/apps/photos/abc.png") ==
             "user/apps/photos/abc_thumb.jpg"
  end

  describe "storage-backed generation" do
    setup do
      base = Path.join(System.tmp_dir!(), "thumb_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      previous = {System.get_env("FILES_DIR"), System.get_env("TMP_DIR")}
      System.put_env("FILES_DIR", Path.join(base, "files"))
      System.put_env("TMP_DIR", Path.join(base, "tmp"))

      on_exit(fn ->
        {files, tmp} = previous
        restore_env("FILES_DIR", files)
        restore_env("TMP_DIR", tmp)
        File.rm_rf(base)
      end)

      %{user: user_fixture()}
    end

    defp restore_env(key, nil), do: System.delete_env(key)
    defp restore_env(key, value), do: System.put_env(key, value)

    defp store_photo(user_id) do
      source = Path.join(System.tmp_dir!(), "src-#{System.unique_integer([:positive])}.jpg")
      :ok = write_minimal_jpeg(source)
      on_exit(fn -> File.rm(source) end)

      {:ok, relative, absolute} = Storage.store_app_file(user_id, "photos", source, ext: ".jpg")
      {relative, absolute}
    end

    test "creates the thumbnail next to the stored file", %{user: user} do
      {relative, absolute} = store_photo(user.id)

      assert {:ok, url, thumb_relative} = Thumbnail.create_for_storage(relative, absolute)
      assert url == Storage.public_url(thumb_relative)
      assert File.regular?(Storage.join_files([thumb_relative]))
    end

    test "an existing thumbnail is reused instead of regenerated", %{user: user} do
      {relative, absolute} = store_photo(user.id)
      assert {:ok, _url, thumb_relative} = Thumbnail.create_for_storage(relative, absolute)

      path = Storage.join_files([thumb_relative])
      File.write!(path, "sentinel")

      assert {:ok, _url, ^thumb_relative} = Thumbnail.create_for_storage(relative, absolute)
      assert File.read!(path) == "sentinel"
    end

    test "creates a display JPEG for browser-hostile formats", %{user: user} do
      {relative, absolute} = store_photo(user.id)

      assert {:ok, _url, display_relative} =
               Thumbnail.create_display_for_storage(relative, absolute)

      assert File.regular?(Storage.join_files([display_relative]))
      assert display_relative != Storage.thumb_relative(relative)
    end

    test "works from the public URL the entries carry", %{user: user} do
      {relative, _absolute} = store_photo(user.id)

      assert {:ok, _url, _thumb} = Thumbnail.create_for_public_path(Storage.public_url(relative))

      assert {:ok, _url, _display} =
               Thumbnail.create_display_for_public_path(Storage.public_url(relative))
    end

    test "a path that resolves to nothing is an error, not a crash" do
      assert Thumbnail.create_for_public_path("/files/nope/missing.jpg") == :error
      assert Thumbnail.create_for_public_path(nil) == :error
      assert Thumbnail.create_display_for_public_path("/files/../etc/passwd") == :error
      assert Thumbnail.create_display_for_public_path(42) == :error
    end

    test "a source that is not an image fails without raising", %{user: user} do
      source = Path.join(System.tmp_dir!(), "not-an-image-#{System.unique_integer([:positive])}")
      File.write!(source, "definitely not a jpeg")
      on_exit(fn -> File.rm(source) end)

      {:ok, relative, absolute} = Storage.store_app_file(user.id, "photos", source, ext: ".jpg")
      assert Thumbnail.create_for_storage(relative, absolute) == :error
    end
  end

  describe "backfill_missing/1" do
    setup do
      base = Path.join(System.tmp_dir!(), "backfill_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      previous = {System.get_env("FILES_DIR"), System.get_env("TMP_DIR")}
      System.put_env("FILES_DIR", Path.join(base, "files"))
      System.put_env("TMP_DIR", Path.join(base, "tmp"))

      on_exit(fn ->
        {files, tmp} = previous
        restore_env("FILES_DIR", files)
        restore_env("TMP_DIR", tmp)
        File.rm_rf(base)
      end)

      %{user: user_fixture()}
    end

    defp photo_entry(user_id, data) do
      {:ok, entry} =
        Data.create_entry(user_id, %{kind: "photo", source: "upload", title: "Photo", data: data})

      entry
    end

    test "fills in the missing thumbnail and display paths", %{user: user} do
      {relative, _absolute} = store_photo(user.id)
      entry = photo_entry(user.id, %{"path" => Storage.public_url(relative)})

      assert [{:ok, id}] = Thumbnail.backfill_missing(user.id)
      assert id == entry.id

      reloaded = Data.get_entry!(user.id, entry.id)
      assert reloaded.data["thumb_path"] =~ "_thumb.jpg"
      assert reloaded.data["display_path"] =~ "_display.jpg"
    end

    test "entries that already have both are left alone", %{user: user} do
      photo_entry(user.id, %{
        "path" => "/files/x.jpg",
        "thumb_path" => "/files/x_thumb.jpg",
        "display_path" => "/files/x_display.jpg"
      })

      assert Thumbnail.backfill_missing(user.id) == []
    end

    test "an entry with no usable file reports a failure", %{user: user} do
      entry = photo_entry(user.id, %{"path" => "/files/missing/nope.jpg"})

      assert [{:error, id, :thumbnail_failed}] = Thumbnail.backfill_missing(user.id)
      assert id == entry.id
    end

    test "an entry without a path is skipped", %{user: user} do
      photo_entry(user.id, %{"caption" => "no file"})
      assert Thumbnail.backfill_missing(user.id) == []
    end

    test "scopes to one user, or covers everyone when given nil", %{user: user} do
      other = user_fixture()
      photo_entry(user.id, %{"path" => "/files/missing/a.jpg"})
      photo_entry(other.id, %{"path" => "/files/missing/b.jpg"})

      assert length(Thumbnail.backfill_missing(user.id)) == 1
      assert length(Thumbnail.backfill_missing()) == 2
    end

    # The stream keyset-paginates by id. When there are more entries than one
    # batch, each entry must come back exactly one time.
    test "walks past the batch size", %{user: user} do
      for i <- 1..101, do: photo_entry(user.id, %{"path" => "/files/missing/#{i}.jpg"})

      results = Thumbnail.backfill_missing(user.id)
      assert length(results) == 101
      assert length(Enum.uniq(results)) == 101
    end
  end

  defp write_minimal_jpeg(path) do
    jpeg =
      Base.decode64!(
        "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q=="
      )

    File.write(path, jpeg)
  end
end
