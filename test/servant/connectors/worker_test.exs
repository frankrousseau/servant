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

  test "a successful sync creates entries", %{user: user, config: config, pid: pid} do
    Worker.sync_now(user.id, config.id)
    # Flush the cast: the next synchronous call returns only after the worker
    # handled the cast.
    _ = :sys.get_state(pid)

    assert Data.count_entries(user.id) == 1
  end

  test "a successful sync persists the connector cursor", %{
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

  # --- Lifecycle ---

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
    # The worker handles the failed sync (below). This proves that it survived.
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
           # Stale on purpose: a supervisor restart replays these opts.
           config: %{"cursor" => "stale_cursor"},
           schedule: "on_demand"
         ]},
        id: :cursored_worker
      )

    assert %{state: %{cursor: "db_cursor"}} = :sys.get_state(pid)
  end

  test "init hands the owner's user_id to the connector via the config", %{
    user: user,
    pid: pid
  } do
    assert %{state: %{user_id: user_id}} = :sys.get_state(pid)
    assert user_id == user.id
  end

  # --- Config updates reaching a running worker ---

  # --- Failure handling ---

  defp start_worker(user, config_attrs, schedule \\ "on_demand") do
    {:ok, config} =
      Connectors.create_connector_config(
        user.id,
        Map.merge(
          %{"connector_type" => "rss", "name" => "fake", "schedule" => schedule},
          config_attrs
        )
      )

    pid =
      start_supervised!(
        {Worker,
         [
           user_id: user.id,
           connector_module: Servant.FakeConnector,
           config_id: config.id,
           config: config.config,
           schedule: schedule
         ]},
        id: config.id
      )

    {config, pid}
  end

  # Without this protection, a raise inside sync/1 kills the worker and leaves
  # the sync log stuck in "running" forever.
  test "a connector that raises fails the log and keeps the worker alive", %{user: user} do
    {config, pid} = start_worker(user, %{"config" => %{"raise_sync" => true}})

    Worker.sync_now(user.id, config.id)
    _ = :sys.get_state(pid)

    assert Process.alive?(pid)

    assert [log] = Connectors.list_sync_logs(config.id)
    assert log.status == "failed"
    assert log.error =~ "connector blew up"

    updated = Connectors.get_connector_config!(user.id, config.id)
    assert updated.error =~ "connector blew up"
  end

  # When a connector took the trouble to write a sentence, the worker shows it
  # as a sentence, not as an inspected blob.
  test "a string error reaches the config verbatim", %{user: user} do
    {config, pid} = start_worker(user, %{"config" => %{"fail_sync" => "Token refresh failed"}})

    Worker.sync_now(user.id, config.id)
    _ = :sys.get_state(pid)

    updated = Connectors.get_connector_config!(user.id, config.id)
    assert updated.error == "Token refresh failed"
  end

  test "a successful sync clears a previous error", %{user: user, config: config, pid: pid} do
    Connectors.get_connector_config!(user.id, config.id)
    |> Ecto.Changeset.change(%{error: "an error from a previous run"})
    |> Servant.Repo.update!()

    Worker.sync_now(user.id, config.id)
    _ = :sys.get_state(pid)

    assert Connectors.get_connector_config!(user.id, config.id).error == nil
  end

  # --- Scheduling ---

  test "an on_demand worker arms no timer", %{pid: pid, user: user, config: config} do
    assert %{timer_ref: nil} = :sys.get_state(pid)

    Worker.sync_now(user.id, config.id)
    assert %{timer_ref: nil} = :sys.get_state(pid)
  end

  # Before, the manual syncs stacked parallel timer chains. Each chain then
  # fired its own sync forever.
  test "a scheduled worker keeps exactly one pending timer", %{user: user} do
    {config, pid} = start_worker(user, %{"name" => "scheduled"}, "every_hour")

    assert %{timer_ref: first} = :sys.get_state(pid)
    assert is_reference(first)

    Worker.sync_now(user.id, config.id)
    assert %{timer_ref: second} = :sys.get_state(pid)

    assert is_reference(second)
    assert second != first
    # The worker cancels the superseded timer and does not let it fire by itself.
    assert Process.read_timer(first) == false
  end

  describe "update_connector_config/3" do
    setup %{user: user} do
      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "rss",
          "name" => "feed",
          "config" => %{"url" => "https://example.com/old.xml"},
          "schedule" => "on_demand"
        })

      {:ok, pid} = Connectors.start_connector(user.id, config.id)
      on_exit(fn -> Connectors.stop_connector(user.id, config.id) end)

      %{rss_config: config, rss_pid: pid}
    end

    test "a config change restarts the running worker with the new state", %{
      user: user,
      rss_config: config,
      rss_pid: pid
    } do
      ref = Process.monitor(pid)

      {:ok, _updated} =
        Connectors.update_connector_config(user.id, config.id, %{
          "config" => %{"url" => "https://example.com/new.xml"}
        })

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      [{new_pid, _}] = Registry.lookup(Servant.Connectors.Registry, {user.id, config.id})
      assert new_pid != pid
      assert :sys.get_state(new_pid).state.url == "https://example.com/new.xml"
    end

    test "a name-only change leaves the worker alone", %{
      user: user,
      rss_config: config,
      rss_pid: pid
    } do
      {:ok, _updated} =
        Connectors.update_connector_config(user.id, config.id, %{"name" => "renamed"})

      assert Registry.lookup(Servant.Connectors.Registry, {user.id, config.id}) == [{pid, nil}]
    end
  end
end
