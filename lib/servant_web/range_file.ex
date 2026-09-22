defmodule ServantWeb.RangeFile do
  @moduledoc """
  Sends a stored file with the headers every user-file response needs, honouring
  single-range `Range` requests (206) so `<video>` seeking works. Shared by the
  owner-only `/files` route and the public photo-share file route.

  Malformed or multi-range specs fall back to the full file, which RFC 9110
  allows (the header is advisory).
  """

  import Plug.Conn

  @doc "Sends `absolute` (a regular file of `size` bytes) as the response."
  @spec send(Plug.Conn.t(), String.t(), non_neg_integer()) :: Plug.Conn.t()
  def send(conn, absolute, size) do
    conn
    |> put_resp_content_type(MIME.from_path(absolute))
    |> put_resp_header("accept-ranges", "bytes")
    # The files store holds arbitrary user/connector content: keep the
    # declared type honest (no MIME sniffing) and neutralize any stored
    # .html/.svg by sandboxing the response, so navigating to it can't run
    # script on the app origin. Sandbox doesn't affect <img>/<video>
    # embedding (those aren't document contexts).
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "sandbox")
    |> send_range_or_all(absolute, size)
  end

  defp send_range_or_all(conn, absolute, size) do
    with [header] <- get_req_header(conn, "range"),
         {offset, length} when length > 0 <- parse_range(header, size) do
      conn
      |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{size}")
      |> send_file(206, absolute, offset, length)
    else
      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      _ ->
        send_file(conn, 200, absolute)
    end
  end

  # "bytes=start-end" | "bytes=start-" | "bytes=-suffix" -> {offset, length},
  # :unsatisfiable (start past EOF) or :invalid (serve the full file).
  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 ->
            start = max(size - n, 0)
            if start >= size, do: :unsatisfiable, else: {start, size - start}

          _ ->
            :invalid
        end

      [start_s, ""] ->
        case Integer.parse(start_s) do
          {start, ""} when start >= 0 ->
            if start >= size, do: :unsatisfiable, else: {start, size - start}

          _ ->
            :invalid
        end

      [start_s, end_s] ->
        with {start, ""} when start >= 0 <- Integer.parse(start_s),
             {last, ""} when last >= start <- Integer.parse(end_s) do
          if start >= size, do: :unsatisfiable, else: {start, min(last, size - 1) - start + 1}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_range(_, _), do: :invalid
end
