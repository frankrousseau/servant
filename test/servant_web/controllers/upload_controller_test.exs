defmodule ServantWeb.UploadControllerTest do
  # async: false — mutates the FILES_DIR env var.
  use ServantWeb.ConnCase, async: false

  setup %{conn: conn} do
    dir =
      Path.join(System.tmp_dir!(), "servant_upload_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    prev = System.get_env("FILES_DIR")
    System.put_env("FILES_DIR", dir)

    on_exit(fn ->
      if prev, do: System.put_env("FILES_DIR", prev), else: System.delete_env("FILES_DIR")
      File.rm_rf(dir)
    end)

    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp upload(content, filename, content_type) do
    path = Path.join(System.tmp_dir!(), "upl_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  test "stores a file and returns its public path", %{conn: conn} do
    conn =
      post(conn, "/api/uploads", %{
        "file" => upload("hello world", "note.txt", "text/plain"),
        "app" => "files"
      })

    assert %{"path" => path, "filename" => "note.txt", "size" => size, "app" => "files"} =
             json_response(conn, 200)

    assert String.starts_with?(path, "/files/")
    assert size == byte_size("hello world")
  end

  test "keeps the .heic extension when the browser sends octet-stream", %{conn: conn} do
    conn =
      post(conn, "/api/uploads", %{
        "file" => upload("not a real heic", "IMG_0001.heic", "application/octet-stream"),
        "app" => "photos"
      })

    assert %{"path" => path} = json_response(conn, 200)
    assert String.ends_with?(path, ".heic")
    # Bogus bytes: thumbnail/display generation must fail gracefully.
    refute Map.has_key?(json_response(conn, 200), "thumb_path")
    refute Map.has_key?(json_response(conn, 200), "display_path")
  end

  test "422 when no file is given", %{conn: conn} do
    conn = post(conn, "/api/uploads", %{"app" => "files"})
    assert %{"error" => _} = json_response(conn, 422)
  end

  test "rejects a file over the size limit", %{conn: conn} do
    # Shrink the limit so the test doesn't have to write a 1GB file.
    Application.put_env(:servant, :max_upload_size, 1_000)
    on_exit(fn -> Application.delete_env(:servant, :max_upload_size) end)

    big = :binary.copy("x", 1_001)

    conn =
      post(conn, "/api/uploads", %{
        "file" => upload(big, "big.bin", "application/octet-stream"),
        "app" => "files"
      })

    assert json_response(conn, 413)
  end
end
