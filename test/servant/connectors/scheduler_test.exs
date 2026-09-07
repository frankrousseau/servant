defmodule Servant.Connectors.SchedulerTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.Scheduler

  defp bank_config(user_id, attrs) do
    {:ok, config} =
      Connectors.create_connector_config(
        user_id,
        Map.merge(%{"connector_type" => "bank_csv", "name" => "Bank"}, attrs)
      )

    config
  end

  test "starts the enabled connectors on boot and leaves the disabled ones alone" do
    user = user_fixture()
    enabled = bank_config(user.id, %{"enabled" => true, "schedule" => "on_demand"})
    disabled = bank_config(user.id, %{"enabled" => false, "name" => "Off"})

    on_exit(fn -> Connectors.stop_connector(user.id, enabled.id) end)

    pid = start_supervised!({Scheduler, name: :test_connector_scheduler})
    # handle_continue has run once the process answers
    _ = :sys.get_state(pid)

    assert [{_pid, _}] = Registry.lookup(Servant.Connectors.Registry, {user.id, enabled.id})
    assert [] == Registry.lookup(Servant.Connectors.Registry, {user.id, disabled.id})
  end

  # A connector whose config no longer starts must not take the boot down with
  # it: every other user's workers depend on this sweep finishing.
  test "a connector that cannot start does not stop the boot sweep" do
    user = user_fixture()
    broken = bank_config(user.id, %{"enabled" => true, "config" => %{"preset" => "nope"}})
    healthy = bank_config(user.id, %{"enabled" => true, "name" => "Good"})

    on_exit(fn -> Connectors.stop_connector(user.id, healthy.id) end)

    pid = start_supervised!({Scheduler, name: :test_connector_scheduler})
    _ = :sys.get_state(pid)

    assert [] == Registry.lookup(Servant.Connectors.Registry, {user.id, broken.id})
    assert [{_pid, _}] = Registry.lookup(Servant.Connectors.Registry, {user.id, healthy.id})
  end

  test "the daily sweep drops expired shared-env rows and keeps the live ones" do
    yesterday = DateTime.add(DateTime.utc_now(), -1, :day)
    tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

    Connectors.put_env("solana", "token_metadata", "stale", %{"data" => %{}}, yesterday)
    Connectors.put_env("solana", "token_metadata", "fresh", %{"data" => %{}}, tomorrow)
    Connectors.put_env("solana", "token_metadata", "forever", %{"data" => %{}})

    pid = start_supervised!({Scheduler, name: :test_connector_scheduler})
    send(pid, :cleanup_env)
    _ = :sys.get_state(pid)

    refute Connectors.get_env("solana", "token_metadata", "stale")
    assert Connectors.get_env("solana", "token_metadata", "fresh")
    assert Connectors.get_env("solana", "token_metadata", "forever")
  end
end
