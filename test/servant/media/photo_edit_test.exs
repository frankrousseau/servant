defmodule Servant.Media.PhotoEditTest do
  use ServantWeb.ConnCase, async: false

  alias Servant.Storage
  alias Vix.Vips.{Image, Operation}

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)

    relative = Path.join([user.id, "apps", "photos", "rotate-test.jpg"])
    absolute = Storage.join_files([relative])
    File.mkdir_p!(Path.dirname(absolute))

    {:ok, img} = Operation.black(40, 20)
    :ok = Image.write_to_file(img, absolute, Q: 90)

    on_exit(fn -> File.rm_rf!(Storage.join_files([user.id])) end)

    {:ok, entry} =
      Servant.Data.create_entry(user.id, %{
        "kind" => "photo",
        "source" => "manual",
        "title" => "rotate-test.jpg",
        "data" => %{"path" => Storage.public_url(relative), "mime_type" => "image/jpeg"}
      })

    %{conn: conn, user: user, entry: entry, absolute: absolute}
  end

  defp file_of(public_url), do: Storage.join_files([Storage.relative_from_public(public_url)])

  test "rotates into a new file, regenerates derived files, deletes the old ones", ctx do
    conn = post(ctx.conn, ~p"/api/entries/#{ctx.entry.id}/rotate_photo?angle=90")
    data = json_response(conn, 200)["data"]["data"]

    assert data["path"] != ctx.entry.data["path"]
    refute File.exists?(ctx.absolute)

    {:ok, img} = Image.new_from_file(file_of(data["path"]))
    assert {Image.width(img), Image.height(img)} == {20, 40}
    assert File.regular?(file_of(data["thumb_path"]))
    assert File.regular?(file_of(data["display_path"]))

    conn = post(ctx.conn, ~p"/api/entries/#{ctx.entry.id}/rotate_photo?angle=90")
    data2 = json_response(conn, 200)["data"]["data"]
    refute File.exists?(file_of(data["path"]))

    {:ok, img} = Image.new_from_file(file_of(data2["path"]))
    assert {Image.width(img), Image.height(img)} == {40, 20}
  end

  test "rejects invalid angles", ctx do
    conn = post(ctx.conn, ~p"/api/entries/#{ctx.entry.id}/rotate_photo?angle=45")
    assert json_response(conn, 422)["error"] =~ "angle"
  end

  test "rejects videos", ctx do
    {:ok, video} =
      Servant.Data.create_entry(ctx.user.id, %{
        "kind" => "photo",
        "source" => "manual",
        "data" => %{"path" => "/files/x.mp4", "mime_type" => "video/mp4"}
      })

    conn = post(ctx.conn, ~p"/api/entries/#{video.id}/rotate_photo?angle=90")
    assert json_response(conn, 422)["error"] =~ "Only photos"
  end
end
