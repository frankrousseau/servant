defmodule Servant.Media.VideoMeta do
  @moduledoc """
  Extracts the creation date from MP4/QuickTime containers (.mp4, .mov). It
  walks the box structure down to `moov/mvhd`. This is pure binary parsing,
  with no system dependencies. WebM has no standard creation date, so the
  function returns :error for it.
  """

  # Seconds between the QuickTime epoch (1904-01-01) and the Unix epoch.
  @qt_epoch_offset 2_082_844_800

  @doc """
  Returns `{:ok, %DateTime{}}` (UTC) or `:error`.
  """
  def creation_date(path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          size = File.stat!(path).size

          with {:ok, moov_off, moov_size} <- find_box(io, 0, size, "moov"),
               {:ok, mvhd_off, _} <- find_box(io, moov_off, moov_off + moov_size, "mvhd"),
               {:ok, dt} <- read_mvhd(io, mvhd_off) do
            {:ok, dt}
          else
            _ -> :error
          end
        after
          File.close(io)
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # Scans the sibling boxes in [offset, stop) for `type`. Returns the content
  # bounds (after the box header).
  defp find_box(_io, offset, stop, _type) when offset >= stop, do: :error

  defp find_box(io, offset, stop, type) do
    case :file.pread(io, offset, 16) do
      {:ok, <<size::32, box_type::binary-size(4), rest::binary>>} ->
        {header, box_size} =
          case size do
            1 ->
              case rest do
                <<large::64>> -> {16, large}
                _ -> {16, 0}
              end

            # A size of 0 means that the box extends to the end of the file.
            0 ->
              {8, stop - offset}

            _ ->
              {8, size}
          end

        cond do
          box_size < header -> :error
          box_type == type -> {:ok, offset + header, box_size - header}
          true -> find_box(io, offset + box_size, stop, type)
        end

      _ ->
        :error
    end
  end

  defp read_mvhd(io, offset) do
    case :file.pread(io, offset, 12) do
      {:ok, <<0, _flags::binary-size(3), ctime::32, _::binary>>} -> qt_time(ctime)
      {:ok, <<1, _flags::binary-size(3), ctime::64>>} -> qt_time(ctime)
      _ -> :error
    end
  end

  # 0 means "not set" in the spec.
  defp qt_time(0), do: :error

  defp qt_time(seconds) do
    case DateTime.from_unix(seconds - @qt_epoch_offset) do
      # Sanity: some encoders write garbage. Trust only plausible dates.
      {:ok, dt} when dt.year >= 1970 and dt.year <= 2100 -> {:ok, dt}
      _ -> :error
    end
  end
end
