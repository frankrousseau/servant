defmodule Servant.Connectors.EVM.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EVM.RateLimiter

  # The reservation logic alone: wait/1 is a no-op in tests (no sleeping).
  defp reserve(state, key), do: RateLimiter.handle_call({:reserve, key}, self(), state)

  test "back-to-back calls on one key are spaced, other keys are independent" do
    {:reply, first, state} = reserve(%{}, "KEY")
    {:reply, second, state} = reserve(state, "KEY")
    {:reply, third, state} = reserve(state, "KEY")
    {:reply, other, _state} = reserve(state, "OTHER")

    assert first == 0
    assert second in 390..400
    assert third in 790..800
    assert other == 0
  end
end
