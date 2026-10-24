defmodule Servant.Auth.Throttle do
  @moduledoc """
  In-memory throttle of the failed attempts for the auth endpoints.

  It caps the failures per key in a rolling window. As a result, an attacker
  who has the password cannot brute force the 6-digit TOTP code. And an
  attacker cannot brute force a lone password online at an offline speed. The
  state is in a public ETS table that this process owns. A success resets the
  state, and the state rolls over at each window. There is no persistence: a
  restart clears the state, which is satisfactory for a lockout.
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
  Returns `:ok` when the key can attempt, or `{:error, retry_after_seconds}` when
  the key is locked for the rest of the current window.
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

  @doc "Records a failed attempt. Starts a new window if the last window is expired."
  # ponytail: with concurrent failures, the read-then-write race can make the
  # count a little too low or too high. This is not important for a lockout
  # threshold.
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

  @doc "Clears the counter of a key. Call it on a successful auth."
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
