defmodule ServantWeb.FilesController do
  @moduledoc """
  Serves persisted files from `FILES_DIR` at `/files/…` (and legacy `/uploads/…`),
  but only to their owner. Requests are authenticated by `ServantWeb.Plugs.FileAuth`
  and scoped to `FILES_DIR/<user_id>/` by `Servant.Storage.resolve_owned_path/2`.
  Range requests and the response headers are handled by `ServantWeb.RangeFile`.
  """
  use ServantWeb, :controller

  alias ServantWeb.RangeFile

  def show(conn, %{"path" => segments}) do
    user = conn.assigns.current_user
    relative = Enum.join(segments, "/")

    with {:ok, absolute} <- Servant.Storage.resolve_owned_path(user.id, relative),
         {:ok, %File.Stat{size: size}} <- File.stat(absolute) do
      RangeFile.send(conn, absolute, size)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
