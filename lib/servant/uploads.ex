defmodule Servant.Uploads do
  @moduledoc """
  Runtime root for user-uploaded files (photos, avatars, app files).
  """

  @doc """
  Absolute path to the uploads directory.
  Uses `UPLOADS_DIR` when set (Docker volume), otherwise release priv/uploads.
  """
  def root do
    case System.get_env("UPLOADS_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(:code.priv_dir(:servant) |> to_string(), "uploads")
    end
  end

  def join(parts) when is_list(parts) do
    Path.join([root() | parts])
  end
end
