defmodule ServantWeb.Plugs.FilesStatic do
  @moduledoc """
  Serves persisted files from `FILES_DIR` at `/files/…`.
  Keeps `/uploads/…` as a legacy prefix for older stored paths.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/files/" <> relative} = conn, _opts) do
    serve(conn, relative)
  end

  def call(%Plug.Conn{request_path: "/uploads/" <> relative} = conn, _opts) do
    serve(conn, relative)
  end

  def call(conn, _opts), do: conn

  defp serve(conn, relative) do
    case Servant.Storage.resolve_public_path(relative) do
      {:ok, path} ->
        conn
        |> put_resp_content_type(MIME.from_path(path))
        |> send_file(200, path)
        |> halt()

      _ ->
        conn
    end
  end
end
