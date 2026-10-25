defmodule Servant.Audit.ErrorLogHandler do
  @moduledoc """
  `:logger` handler that mirrors the log events of level error and worse
  into `Servant.Audit.LogBuffer`. `Servant.Application` installs it after
  the buffer starts (the handler config filters the levels).
  """

  alias Servant.Audit.LogEvent

  @max_message_length 2_000

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    entry = %{
      at: LogEvent.time(meta),
      level: Atom.to_string(level),
      message: msg |> LogEvent.message(meta) |> String.slice(0, @max_message_length)
    }

    Servant.Audit.LogBuffer.record_error(entry)
  catch
    # A log handler that crashes must never crash the logger too.
    _, _ -> :ok
  end
end
