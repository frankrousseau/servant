defmodule Servant.Connectors.EVM.RateLimiter do
  @moduledoc """
  Spaces explorer calls across every EVM connector sharing a key. Etherscan's
  free tier allows 3 calls per second per API key, all chains together, and
  each connector syncs in its own process: without a shared queue, a few
  wallets syncing at once trip "Max calls per sec rate limit reached".

  `wait/1` reserves the next free slot for the key and sleeps until it.
  """

  use GenServer

  # 2.5 calls/s: under the 3/s cap with room for clock jitter.
  @interval_ms 400

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Blocks until the caller may send its next request for `key`."
  @spec wait(term()) :: :ok
  def wait(key) do
    if Application.get_env(:servant, :connector_throttle, true) do
      delay = GenServer.call(__MODULE__, {:reserve, key})
      if delay > 0, do: Process.sleep(delay)
    end

    :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:reserve, key}, _from, next_free) do
    now = System.monotonic_time(:millisecond)
    slot = max(now, Map.get(next_free, key, now))
    {:reply, slot - now, Map.put(next_free, key, slot + @interval_ms)}
  end
end
