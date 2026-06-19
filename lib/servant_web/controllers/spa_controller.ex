defmodule ServantWeb.SpaController do
  use ServantWeb, :controller

  def index(conn, _params) do
    index_path = Path.join(:code.priv_dir(:servant), "static/index.html")

    if File.exists?(index_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "SPA not built. Run npm run build in frontend/"})
    end
  end
end
