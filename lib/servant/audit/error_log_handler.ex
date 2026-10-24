defmodule Servant.Audit.ErrorLogHandler do
  @moduledoc """
  `:logger` handler that mirrors the log events of level error and worse
  into `Servant.Audit.LogBuffer`. `Servant.Application` installs it after
  the buffer starts (the handler config filters the levels).
  """

  @max_message_length 2_000

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    entry = %{
      at: event_time(meta),
      level: Atom.to_string(level),
      message: msg |> format_message(meta) |> String.slice(0, @max_message_length)
    }

    Servant.Audit.LogBuffer.record_error(entry)
  catch
    # A log handler that crashes must never crash the logger too.
    _, _ -> :ok
  end

  defp event_time(%{time: us}) when is_integer(us) do
    us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp event_time(_), do: DateTime.to_iso8601(DateTime.utc_now())

  defp format_message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp format_message({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {fmt, args} = cb.(report)
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp format_message({:report, report}, _meta), do: inspect(report)

  defp format_message({fmt, args}, _meta) when is_list(args) do
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp format_message(other, _meta), do: inspect(other)
end
