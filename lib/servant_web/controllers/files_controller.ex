defmodule ServantWeb.FilesController do
  @moduledoc """
  Serves persisted files from `FILES_DIR` at `/files/…` (and legacy `/uploads/…`),
  but only to their owner. Requests are authenticated by `ServantWeb.Plugs.FileAuth`
  and scoped to `FILES_DIR/<user_id>/` by `Servant.Storage.resolve_owned_path/2`.
  """
  use ServantWeb, :controller

  def show(conn, %{"path" => segments}) do
    user = conn.assigns.current_user
    relative = Enum.join(segments, "/")

    case Servant.Storage.resolve_owned_path(user.id, relative) do
      {:ok, absolute} ->
        conn
        |> put_resp_content_type(MIME.from_path(absolute))
        |> send_file(200, absolute)

      :error ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Not found"})
    end
  end
end
