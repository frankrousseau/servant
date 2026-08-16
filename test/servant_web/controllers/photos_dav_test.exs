defmodule ServantWeb.PhotosDavTest do
  # System.put_env on the storage roots: keep serial.
  use ServantWeb.ConnCase, async: false

  alias Servant.Data

  # Smallest valid JPEG (1x1), same fixture as the thumbnail tests; real
  # enough for libvips to thumbnail it when libvips is available.
  @jpeg Base.decode64!(
          "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA//2Q=="
        )

  setup %{conn: conn} do
    base =
      Path.join(System.tmp_dir!(), "servant-photos-dav-#{System.unique_integer([:positive])}")

    System.put_env("FILES_DIR", Path.join(base, "files"))
    System.put_env("TMP_DIR", Path.join(base, "tmp"))

    on_exit(fn ->
      System.delete_env("FILES_DIR")
      System.delete_env("TMP_DIR")
      File.rm_rf(base)
    end)

    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{
        "name" => "phone",
        "scopes" => ["app:photos:write"]
      })

    conn =
      put_req_header(conn, "authorization", "Basic " <> Base.encode64("frank:#{plaintext}"))

    %{conn: conn, user: user}
  end

  defp dav(conn, method, path, body \\ "") do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> dispatch(@endpoint, method, path, body)
  end

  defp photo_entries(user_id), do: Data.list_entries(user_id, %{"kind" => "photo"})

  test "MKCOL, PUT, PROPFIND, GET: the full round trip", %{conn: conn, user: user} do
    assert dav(conn, "MKCOL", "/dav/photos/Camera").status == 201

    put = dav(conn, "PUT", "/dav/photos/Camera/IMG_0001.jpg", @jpeg)
    assert put.status == 201
    assert [_etag] = get_resp_header(put, "etag")

    root = dav(conn, "PROPFIND", "/dav/photos")
    assert root.status == 207
    assert response(root, 207) =~ "Camera"

    listing = dav(conn, "PROPFIND", "/dav/photos/Camera")
    assert listing.status == 207
    body = response(listing, 207)
    assert body =~ "IMG_0001.jpg"
    assert body =~ "<d:getcontentlength>#{byte_size(@jpeg)}</d:getcontentlength>"
    assert body =~ "image/jpeg"

    got = dav(conn, "GET", "/dav/photos/Camera/IMG_0001.jpg")
    assert got.status == 200
    assert got.resp_body == @jpeg

    [entry] = photo_entries(user.id)
    assert entry.kind == "photo"
    assert entry.source == "webdav"
    assert entry.data["album"] == "Camera"
    assert entry.data["filename"] == "IMG_0001.jpg"
    assert entry.data["mime_type"] == "image/jpeg"
    assert entry.data["size"] == byte_size(@jpeg)
    assert entry.data["path"] =~ "/apps/photos/"
    assert entry.data["tags"] == []
  end

  test "root PUT gets a nil album, nested PUT a slash-joined one", %{conn: conn, user: user} do
    assert dav(conn, "PUT", "/dav/photos/root.jpg", @jpeg).status == 201
    assert dav(conn, "PUT", "/dav/photos/Camera/2026-08/nested.jpg", @jpeg).status == 201

    albums = user.id |> photo_entries() |> Enum.map(& &1.data["album"]) |> Enum.sort()
    assert albums == [nil, "Camera/2026-08"]

    root = response(dav(conn, "PROPFIND", "/dav/photos"), 207)
    assert root =~ "root.jpg"
    assert root =~ ">Camera<"
    refute root =~ "nested.jpg"

    camera = response(dav(conn, "PROPFIND", "/dav/photos/Camera"), 207)
    assert camera =~ ">2026-08<"

    sub = response(dav(conn, "PROPFIND", "/dav/photos/Camera/2026-08"), 207)
    assert sub =~ "nested.jpg"
  end

  test "PUT on an existing name updates the entry in place", %{conn: conn, user: user} do
    assert dav(conn, "PUT", "/dav/photos/Camera/IMG.jpg", @jpeg).status == 201
    [entry] = photo_entries(user.id)
    old_path = entry.data["path"]

    {:ok, _} =
      Data.update_entry(user.id, entry.id, %{data: Map.put(entry.data, "tags", ["vacances"])})

    assert dav(conn, "PUT", "/dav/photos/Camera/IMG.jpg", @jpeg <> @jpeg).status == 204

    [updated] = photo_entries(user.id)
    assert updated.id == entry.id
    assert updated.data["tags"] == ["vacances"]
    assert updated.data["size"] == byte_size(@jpeg) * 2
    assert updated.data["path"] != old_path

    relative = Servant.Storage.relative_from_public(old_path)
    assert Servant.Storage.resolve_owned_path(user.id, relative) == :error
  end

  test "X-OC-MTime backfills occurred_at when the media has no date", %{
    conn: conn,
    user: user
  } do
    put =
      conn
      |> put_req_header("x-oc-mtime", "1700000000")
      |> dav("PUT", "/dav/photos/old.bin", "no exif here")

    assert put.status == 201
    assert get_resp_header(put, "x-oc-mtime") == ["accepted"]

    [entry] = photo_entries(user.id)
    assert entry.occurred_at == ~U[2023-11-14 22:13:20Z]
  end

  test "a HEIC body the server cannot decode still lands as an entry", %{
    conn: conn,
    user: user
  } do
    assert dav(conn, "PUT", "/dav/photos/Camera/IMG_0002.heic", "not a real heic").status == 201

    [entry] = photo_entries(user.id)
    assert entry.data["filename"] == "IMG_0002.heic"
    refute Map.has_key?(entry.data, "thumb_path")
    refute Map.has_key?(entry.data, "display_path")
  end

  test "DELETE removes a photo, an album delete is recursive", %{conn: conn, user: user} do
    assert dav(conn, "PUT", "/dav/photos/Old/a.jpg", @jpeg).status == 201
    assert dav(conn, "PUT", "/dav/photos/Old/Sub/b.jpg", @jpeg).status == 201
    assert dav(conn, "PUT", "/dav/photos/Keep/c.jpg", @jpeg).status == 201

    assert dav(conn, "DELETE", "/dav/photos/Old/a.jpg").status == 204
    assert dav(conn, "GET", "/dav/photos/Old/a.jpg").status == 404

    assert dav(conn, "DELETE", "/dav/photos/Old").status == 204

    remaining = photo_entries(user.id)
    assert Enum.map(remaining, & &1.data["filename"]) == ["c.jpg"]
  end

  test "MKCOL guards and empty-album PROPFIND", %{conn: conn} do
    assert dav(conn, "MKCOL", "/dav/photos/Fresh").status == 201

    # A just-created album is virtual but must list as an empty collection.
    listing = dav(conn, "PROPFIND", "/dav/photos/Fresh")
    assert listing.status == 207

    assert dav(conn, "PUT", "/dav/photos/Fresh/x.jpg", @jpeg).status == 201
    assert dav(conn, "MKCOL", "/dav/photos/Fresh").status == 405

    assert dav(conn, "PROPFIND", "/dav/photos/absent.jpg").status == 404
    assert dav(conn, "GET", "/dav/photos/absent.jpg").status == 404
  end

  test "photos tree needs the photos scope, files scope is not enough", %{conn: conn} do
    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{
        "name" => "files-only",
        "scopes" => ["app:files:write"]
      })

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Basic " <> Base.encode64("frank:#{plaintext}"))

    assert dav(conn, "PUT", "/dav/photos/x.jpg", @jpeg).status == 403
    assert dav(conn, "PROPFIND", "/dav/photos").status == 403
    assert dav(conn, "PUT", "/dav/files/x.txt", "x").status == 201
  end

  test "the photos token cannot write the files tree", %{conn: conn} do
    assert dav(conn, "PUT", "/dav/files/x.txt", "x").status == 403
  end
end
