defmodule Servant.Connectors.SyncTrace do
  @moduledoc """
  Records what one connector sync does, for its sync log: the HTTP calls it
  makes (Finch telemetry) and the lines it logs (a `:logger` handler).

  The worker opens a trace in its own process dictionary before a run
  (`start/0`) and closes it after (`finish/0`). Both handlers run in the
  process that makes the call or logs the line, so they only ever see the
  trace of that run; outside an open trace, they do nothing.

  A call keeps its method, host, path, status and duration only: the query
  string, the headers and the bodies can carry secrets. Work a connector
  hands to another process (a `Task`) is not traced.
  """

  alias Servant.Audit.LogEvent

  @trace_key {__MODULE__, :trace}
  @status_key {__MODULE__, :status}
  @telemetry_id "servant-sync-trace"
  @logger_id :servant_sync_trace
  @max_http 100
  @max_logs 200
  @max_message_length 2_000

  @type t :: %{
          http: [map()],
          http_omitted: non_neg_integer(),
          logs: [map()],
          logs_omitted: non_neg_integer()
        }

  @doc """
  Attaches the telemetry and `:logger` handlers. Called once at boot; a
  second call is harmless (both report the handler as already there).
  """
  @spec attach() :: :ok
  def attach do
    _ =
      :telemetry.attach_many(
        @telemetry_id,
        [[:finch, :recv, :stop], [:finch, :request, :stop], [:finch, :request, :exception]],
        &__MODULE__.handle_event/4,
        nil
      )

    _ = :logger.add_handler(@logger_id, __MODULE__, %{level: :all})
    :ok
  end

  @doc "Opens a trace in the calling process, replacing any leftover one."
  @spec start() :: :ok
  def start do
    Process.delete(@status_key)
    Process.put(@trace_key, empty())
    :ok
  end

  @doc """
  Closes the trace of the calling process and returns it, calls and lines
  in the order they happened; an empty trace when none was open.
  """
  @spec finish() :: t()
  def finish do
    Process.delete(@status_key)

    case Process.delete(@trace_key) do
      nil -> empty()
      trace -> %{trace | http: Enum.reverse(trace.http), logs: Enum.reverse(trace.logs)}
    end
  end

  @doc "Whether the calling process holds an open trace."
  @spec active?() :: boolean()
  def active?, do: Process.get(@trace_key) != nil

  @doc """
  The counts a sync log keeps as columns, and its `details`: the trace
  merged with what the worker adds (`kinds`, `new_entries`, `stacktrace`).
  """
  @spec summary(t(), map()) :: map()
  def summary(trace, details) do
    %{
      http_count: length(trace.http) + trace.http_omitted,
      http_failed_count: Enum.count(trace.http, &failed_call?/1),
      log_count: length(trace.logs) + trace.logs_omitted,
      details: Map.merge(trace, details)
    }
  end

  defp failed_call?(call), do: Map.has_key?(call, :error) or (call.status || 0) >= 400

  @doc false
  # Telemetry handler. The status comes first, with the response; the
  # request stop then closes the call with its total duration.
  def handle_event([:finch, :recv, :stop], _measurements, metadata, _config) do
    if active?(), do: Process.put(@status_key, metadata[:status])
    :ok
  catch
    _, _ -> :ok
  end

  def handle_event(
        [:finch, :request, event],
        measurements,
        %{request: request} = metadata,
        _config
      )
      when event in [:stop, :exception] do
    if active?() do
      %{
        method: request.method,
        host: request.host,
        path: request.path,
        status: Process.delete(@status_key),
        ms: System.convert_time_unit(measurements[:duration] || 0, :native, :millisecond)
      }
      |> put_error(event, metadata)
      |> record(:http, :http_omitted, @max_http)
    end

    :ok
  catch
    _, _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  # `:logger` handler callback, run in the process that logs.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    if active?() do
      record(
        %{
          at: LogEvent.time(meta),
          level: Atom.to_string(level),
          message: msg |> LogEvent.message(meta) |> String.slice(0, @max_message_length)
        },
        :logs,
        :logs_omitted,
        @max_logs
      )
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp empty, do: %{http: [], http_omitted: 0, logs: [], logs_omitted: 0}

  # A request that failed before any response (DNS, TLS, timeout) has no
  # status: the error says why.
  defp put_error(call, :stop, %{result: {:error, error}}),
    do: Map.put(call, :error, error_text(error))

  defp put_error(call, :exception, metadata),
    do: Map.put(call, :error, error_text(metadata[:reason]))

  defp put_error(call, _event, _metadata), do: call

  defp error_text(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error_text(reason), do: inspect(reason)

  defp record(item, list, omitted, max) do
    trace = Process.get(@trace_key)

    trace =
      if length(Map.fetch!(trace, list)) < max,
        do: Map.update!(trace, list, &[item | &1]),
        else: Map.update!(trace, omitted, &(&1 + 1))

    Process.put(@trace_key, trace)
  end
end
