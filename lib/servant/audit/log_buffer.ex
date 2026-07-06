defmodule Servant.Audit.LogBuffer do
  @moduledoc """
  In-memory ring buffers for the Audit page: one for HTTP access lines
  (fed by `ServantWeb.Plugs.AccessLog`) and one for error-level log events
  (fed by `Servant.Audit.ErrorLogHandler`). Newest first, capped, gone on
  restart: a viewport on the running server, not an archive.
  """

  use GenServer

  @max 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def record_access(entry, server \\ __MODULE__),
    do: GenServer.cast(server, {:record, :access, entry})

  def record_error(entry, server \\ __MODULE__),
    do: GenServer.cast(server, {:record, :error, entry})

  def access_logs(server \\ __MODULE__), do: GenServer.call(server, {:logs, :access})
  def error_logs(server \\ __MODULE__), do: GenServer.call(server, {:logs, :error})

  @impl true
  def init(:ok) do
    {:ok, %{access: [], error: []}}
  end

  @impl true
  def handle_cast({:record, kind, entry}, state) do
    # ponytail: Enum.take/2 on every insert is O(@max); switch to :queue if
    # the buffers ever grow beyond a few hundred entries.
    {:noreply, Map.update!(state, kind, &Enum.take([entry | &1], @max))}
  end

  @impl true
  def handle_call({:logs, kind}, _from, state) do
    {:reply, Map.fetch!(state, kind), state}
  end
end
