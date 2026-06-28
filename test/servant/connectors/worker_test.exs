defmodule Servant.Connectors.WorkerTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.Worker
  alias Servant.Data

  setup do
    user = user_fixture()

    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "fake",
        "config" => %{"cursor" => "start"},
        "schedule" => "on_demand"
      })

    pid =
      start_supervised!(
        {Worker,
         [
           user_id: user.id,
           connector_module: Servant.FakeConnector,
           config_id: config.id,
           config: config.config,
           schedule: "on_demand"
         ]}
      )

    %{user: user, config: config, pid: pid}
  end

  test "a successful sync creates entries (BE-TEST-7)", %{user: user, config: config, pid: pid} do
    Worker.sync_now(user.id, config.id)
    # Flush the cast: a following synchronous call returns only once the cast
    # has been handled.
    _ = :sys.get_state(pid)

    assert Data.count_entries(user.id) == 1
  end

  test "a successful sync persists the connector cursor (BE-TEST-7 / BE-ARCH-1)", %{
    user: user,
    config: config,
    pid: pid
  } do
    Worker.sync_now(user.id, config.id)
    _ = :sys.get_state(pid)

    updated = Connectors.get_connector_config!(user.id, config.id)
    assert updated.config["cursor"] == "advanced"
    assert updated.last_synced_at != nil
  end
end
