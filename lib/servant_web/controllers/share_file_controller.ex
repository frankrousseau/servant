defmodule ServantWeb.ShareFileController do
  @moduledoc """
  Serves the files of a public photo feed at `/share/<token>/files/…`. These
  are the original, the thumbnail or the display copy of a photo that is in
  the feed at that time, and nothing else from the store of the owner. There
  is no authentication: the token is the credential. An unknown or revoked
  token is a plain 404.
  """

  use ServantWeb, :controller

  alias Servant.PhotoShares
  alias ServantWeb.RangeFile

  def show(conn, %{"token" => token, "path" => segments}) do
    with share when not is_nil(share) <- PhotoShares.get_by_token(token),
         {:ok, absolute} <- PhotoShares.resolve_file(share, Enum.join(segments, "/")),
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
