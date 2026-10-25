defmodule Servant.Audit.LogEvent do
  @moduledoc """
  A `:logger` event as text: its time in ISO 8601 and its message as a
  string, whatever form the message took (string, report, format and
  arguments). Shared by the `:logger` handlers
  (`Servant.Audit.ErrorLogHandler`, `Servant.Connectors.SyncTrace`).
  """

  @doc "The time of the event, ISO 8601; now when the event carries none."
  @spec time(map()) :: String.t()
  def time(%{time: us}) when is_integer(us) do
    us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  def time(_meta), do: DateTime.to_iso8601(DateTime.utc_now())

  @doc "The message of the event as a string."
  @spec message(term(), map()) :: String.t()
  def message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  def message({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {fmt, args} = cb.(report)
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  def message({:report, report}, _meta), do: inspect(report)

  def message({fmt, args}, _meta) when is_list(args) do
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  def message(other, _meta), do: inspect(other)
end
