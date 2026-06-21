defmodule Servant.Media.Thumbnail do
  @moduledoc """
  Generates JPEG thumbnails for photo uploads using libvips (via Vix).
  """

  alias Vix.Vips.{Image, Operation}

  @max_width 400
  @quality 80

  @doc """
  Creates a JPEG thumbnail at `dest_path` from the image at `source_path`.
  Returns `:ok` or `:error`.
  """
  def generate(source_path, dest_path) do
    File.mkdir_p!(Path.dirname(dest_path))

    with {:ok, thumb} <- Operation.thumbnail(source_path, @max_width, size: :VIPS_SIZE_DOWN),
         :ok <- Image.write_to_file(thumb, dest_path, Q: @quality, strip: true) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
