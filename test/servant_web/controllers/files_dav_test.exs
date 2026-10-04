defmodule ServantWeb.FilesDavTest do
  # This module calls System.put_env on the storage roots. Keep it serial.
  use ServantWeb.ConnCase, async: false

  alias Servant.Data

  setup %{conn: conn} do
    base = Path.join(System.tmp_dir!(), "servant-files-dav-#{System.unique_integer([:positive])}")
    System.put_env("FILES_DIR", Path.join(base, "files"))
    System.put_env("TMP_DIR", Path.join(base, "tmp"))

    on_exit(fn ->
      System.delete_env("FILES_DIR")
      System.delete_env("TMP_DIR")
      File.rm_rf(base)
    end)

    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{"name" => "phone", "scopes" => ["data:write"]})

    conn =
      put_req_header(conn, "authorization", "Basic " <> Base.encode64("frank:#{plaintext}"))

    %{conn: conn, user: user}
  end

  defp dav(conn, method, path, body \\ "") do
    conn
    |> put_req_header("content-type", "application/octet-stream")
    |> dispatch(@endpoint, method, path, body)
  end

  test "MKCOL, PUT, PROPFIND, GET: the full round trip", %{conn: conn, user: user} do
    assert dav(conn, "MKCOL", "/dav/files/Camera").status == 201

    put = dav(conn, "PUT", "/dav/files/Camera/IMG_0001.jpg", "jpegbytes")
    assert put.status == 201
    assert [_etag] = get_resp_header(put, "etag")

    listing = dav(conn, "PROPFIND", "/dav/files/Camera")
    assert listing.status == 207
    body = response(listing, 207)
    assert body =~ "IMG_0001.jpg"
    assert body =~ "<d:getcontentlength>9</d:getcontentlength>"
    assert body =~ "image/jpeg"

    got = dav(conn, "GET", "/dav/files/Camera/IMG_0001.jpg")
    assert got.status == 200
    assert got.resp_body == "jpegbytes"

    # The file is a regular Files-app entry, visible to the SPA.
    [entry] = Data.list_entries(user.id, %{"kind" => "file", "q" => "IMG_0001"})
    assert entry.source == "webdav"
    assert entry.data["parent_id"] != nil
  end

  test "PUT on an existing name replaces content without duplicating", %{
    conn: conn,
    user: user
  } do
    assert dav(conn, "PUT", "/dav/files/note.txt", "v1").status == 201
    assert dav(conn, "PUT", "/dav/files/note.txt", "v2").status == 204

    got = dav(conn, "GET", "/dav/files/note.txt")
    assert got.resp_body == "v2"

    files = Data.list_entries(user.id, %{"kind" => "file"})
    assert length(files) == 1
  end

  test "MKCOL guards: existing name 405, missing intermediate 409", %{conn: conn} do
    assert dav(conn, "MKCOL", "/dav/files/Camera").status == 201
    assert dav(conn, "MKCOL", "/dav/files/Camera").status == 405
    assert dav(conn, "MKCOL", "/dav/files/absent/Sub").status == 409
    assert dav(conn, "PUT", "/dav/files/absent/x.txt", "x").status == 409
  end

  test "DELETE removes a folder and everything below it", %{conn: conn, user: user} do
    assert dav(conn, "MKCOL", "/dav/files/Old").status == 201
    assert dav(conn, "PUT", "/dav/files/Old/a.txt", "a").status == 201
    assert dav(conn, "PUT", "/dav/files/Old/b.txt", "b").status == 201

    assert dav(conn, "DELETE", "/dav/files/Old").status == 204
    assert dav(conn, "GET", "/dav/files/Old/a.txt").status == 404
    assert Data.list_entries(user.id, %{"kind" => "file"}) == []
  end

  test "files tree needs the files write scope", %{conn: conn} do
    user = user_fixture()

    {:ok, _token, plaintext} =
      Servant.ApiTokens.create_token(user.id, %{
        "name" => "cal-only",
        "scopes" => ["app:calendar:write"]
      })

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Basic " <> Base.encode64("frank:#{plaintext}"))

    assert dav(conn, "MKCOL", "/dav/files/Camera").status == 403
    assert dav(conn, "PROPFIND", "/dav/files").status == 403
  end
end
