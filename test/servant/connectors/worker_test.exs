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

  # --- Lifecycle (BE2-TEST-2 / BE2-BUG-1/12) ---

  test "the worker is :transient so an init config error isn't restart-stormed" do
    assert %{restart: :transient} = Worker.child_spec([])
  end

  test "a connector that fails init stops without restarting", %{user: user} do
    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "bad",
        "config" => %{"fail_init" => true},
        "schedule" => "on_demand"
      })

    # {:stop, reason} from init is a failed start, not a crash-loop.
    assert {:error, _reason} =
             start_supervised(
               {Worker,
                [
                  user_id: user.id,
                  connector_module: Servant.FakeConnector,
                  config_id: config.id,
                  config: config.config,
                  schedule: "on_demand"
                ]}
             )

    assert Connectors.sync_now(user.id, config.id) == {:error, :not_running}
  end

  test "a sync error records a failed log and doesn't crash the worker", %{user: user} do
    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "failing",
        "config" => %{"fail_sync" => true},
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
         ]},
        id: :failing_worker
      )

    Worker.sync_now(user.id, config.id)
    # Handling the failed sync (below) proves the worker survived it
    _ = :sys.get_state(pid)

    assert [log | _] = Connectors.list_sync_logs(config.id)
    assert log.status == "failed"
    assert Connectors.get_connector_config!(user.id, config.id).error =~ "sync_failed"
  end

  test "init re-reads the persisted config from the DB, not stale opts", %{user: user} do
    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "cursored",
        "config" => %{"cursor" => "db_cursor"},
        "schedule" => "on_demand"
      })

    pid =
      start_supervised!(
        {Worker,
         [
           user_id: user.id,
           connector_module: Servant.FakeConnector,
           config_id: config.id,
           # Deliberately stale: a supervisor restart would replay these opts.
           config: %{"cursor" => "stale_cursor"},
           schedule: "on_demand"
         ]},
        id: :cursored_worker
      )

    assert %{state: %{cursor: "db_cursor"}} = :sys.get_state(pid)
  end
end
