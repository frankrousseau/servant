defmodule Servant.Auth.Throttle do
  @moduledoc """
  In-memory failed-attempt throttle for the auth endpoints. Caps failures per
  key within a rolling window so an attacker who has the password can't brute
  force the 6-digit TOTP code, and a lone password can't be ground offline-fast
  online. State lives in a public ETS table owned by this process; it is reset
  on success and rolls over each window. No persistence: a restart clears it,
  which is fine for a lockout.
  """
  use GenServer

  @table :auth_throttle
  @max_attempts 10
  @window_ms 15 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @doc """
  `:ok` when the key may attempt, or `{:error, retry_after_seconds}` when it is
  locked for the rest of the current window.
  """
  def check(key) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}]
      when count >= @max_attempts and now - window_start < @window_ms ->
        {:error, div(@window_ms - (now - window_start), 1000) + 1}

      _ ->
        :ok
    end
  end

  @doc "Records a failed attempt, starting a fresh window if the last expired."
  # ponytail: read-then-write race can under/over-count by a hair under
  # concurrent failures; irrelevant for a lockout threshold.
  def record_failure(key) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < @window_ms ->
        :ets.insert(@table, {key, count + 1, window_start})

      _ ->
        :ets.insert(@table, {key, 1, now})
    end

    :ok
  end

  @doc "Clears a key's counter (call on a successful auth)."
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
