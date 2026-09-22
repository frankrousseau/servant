defmodule ServantWeb.ShareControllerTest do
  # System.put_env on FILES_DIR: keep serial.
  use ServantWeb.ConnCase, async: false

  alias Servant.PhotoShares

  setup do
    dir = Path.join(System.tmp_dir!(), "servant_share_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = System.get_env("FILES_DIR")
    System.put_env("FILES_DIR", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
      File.rm_rf(dir)
    end)

    user = user_fixture()
    %{dir: dir, user: user}
  end

  # Writes a file under the user's photos dir and returns its public /files URL.
  defp write_photo_file(dir, user_id, name, content) do
    absolute = Path.join([dir, user_id, "apps", "photos", name])
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)
    "/files/#{user_id}/apps/photos/#{name}"
  end

  defp photo(user_id, tags, data) do
    entry_fixture(user_id, %{
      "kind" => "photo",
      "source" => "photos",
      "title" => "Photo",
      "data" => Map.put(data, "tags", tags)
    })
  end

  test "the feed lists the tagged photos with share-routed URLs", %{
    conn: conn,
    dir: dir,
    user: user
  } do
    path = write_photo_file(dir, user.id, "a.jpg", "jpeg bytes")
    thumb = write_photo_file(dir, user.id, "a_thumb.jpg", "thumb bytes")
    tagged = photo(user.id, ["beach"], %{"path" => path, "thumb_path" => thumb})
    _other = photo(user.id, ["work"], %{"path" => write_photo_file(dir, user.id, "b.jpg", "x")})

    {:ok, share} = PhotoShares.create_share(user.id, %{"name" => "Summer", "tags" => ["beach"]})

    feed = json_response(get(conn, ~p"/api/shares/#{share.token}"), 200)
    assert feed["name"] == "Summer"
    assert feed["tags"] == ["beach"]
    assert [row] = feed["photos"]
    assert row["id"] == tagged.id
    assert row["thumb"] == "/share/#{share.token}/files/#{user.id}/apps/photos/a_thumb.jpg"

    assert response(get(conn, row["thumb"]), 200) == "thumb bytes"
    assert response(get(conn, row["src"]), 200) == "jpeg bytes"
  end

  test "unknown token: 404 for the feed and the files", %{conn: conn} do
    assert json_response(get(conn, ~p"/api/shares/nope"), 404)
    assert json_response(get(conn, "/share/nope/files/whatever.jpg"), 404)
  end

  test "files outside the feed never resolve through the link", %{
    conn: conn,
    dir: dir,
    user: user
  } do
    in_feed = write_photo_file(dir, user.id, "in.jpg", "in")
    out_of_feed = write_photo_file(dir, user.id, "out.jpg", "out")
    photo(user.id, ["beach"], %{"path" => in_feed})
    photo(user.id, ["private"], %{"path" => out_of_feed})
    # A stored file no entry references at all.
    write_photo_file(dir, user.id, "orphan.jpg", "orphan")

    {:ok, share} = PhotoShares.create_share(user.id, %{"tags" => ["beach"]})
    base = "/share/#{share.token}/files/#{user.id}/apps/photos"

    assert response(get(conn, "#{base}/in.jpg"), 200) == "in"
    assert json_response(get(conn, "#{base}/out.jpg"), 404)
    assert json_response(get(conn, "#{base}/orphan.jpg"), 404)
    assert json_response(get(conn, "#{base}/../../account/avatar.png"), 404)
  end

  test "untagging a photo drops it from the feed and the files", %{
    conn: conn,
    dir: dir,
    user: user
  } do
    path = write_photo_file(dir, user.id, "a.jpg", "a")
    entry = photo(user.id, ["beach"], %{"path" => path})
    {:ok, share} = PhotoShares.create_share(user.id, %{"tags" => ["beach"]})
    url = "/share/#{share.token}/files/#{user.id}/apps/photos/a.jpg"
    assert response(get(conn, url), 200) == "a"

    {:ok, _} = Servant.Data.update_entry(user.id, entry.id, %{"data" => %{"path" => path}})

    assert json_response(get(conn, ~p"/api/shares/#{share.token}"), 200)["photos"] == []
    assert json_response(get(conn, url), 404)
  end

  test "range requests work for video seeking", %{conn: conn, dir: dir, user: user} do
    path = write_photo_file(dir, user.id, "clip.mp4", "0123456789")
    photo(user.id, ["clips"], %{"path" => path, "mime_type" => "video/mp4"})
    {:ok, share} = PhotoShares.create_share(user.id, %{"tags" => ["clips"]})

    conn =
      conn
      |> put_req_header("range", "bytes=2-4")
      |> get("/share/#{share.token}/files/#{user.id}/apps/photos/clip.mp4")

    assert response(conn, 206) == "234"
    assert get_resp_header(conn, "content-range") == ["bytes 2-4/10"]
  end
end
