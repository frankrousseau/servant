defmodule Servant.Auth.ThrottleTest do
  use ExUnit.Case, async: false

  alias Servant.Auth.Throttle

  setup do
    # The Throttle process that the app starts owns the table. Use a unique
    # key for each test so that the cases do not interfere.
    key = "test:#{System.unique_integer([:positive])}"
    on_exit(fn -> Throttle.reset(key) end)
    %{key: key}
  end

  test "allows attempts until the cap, then locks with a retry-after", %{key: key} do
    for _ <- 1..10 do
      assert Throttle.check(key) == :ok
      Throttle.record_failure(key)
    end

    assert {:error, retry_after} = Throttle.check(key)
    assert retry_after > 0
  end

  test "reset clears the counter", %{key: key} do
    for _ <- 1..10, do: Throttle.record_failure(key)
    assert {:error, _} = Throttle.check(key)

    Throttle.reset(key)
    assert Throttle.check(key) == :ok
  end
end
