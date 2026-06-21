defmodule ServantWeb.Plugs.UploadsStatic do
  @moduledoc """
  Serves files from the runtime uploads directory (`UPLOADS_DIR` or priv/uploads).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/uploads/" <> relative} = conn, _opts) do
    relative = URI.decode(relative)

    if String.contains?(relative, "..") do
      conn
    else
      path = Servant.Uploads.join([relative])

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          conn
          |> put_resp_content_type(MIME.from_path(path))
          |> send_file(200, path)
          |> halt()

        _ ->
          conn
      end
    end
  end

  def call(conn, _opts), do: conn
end
