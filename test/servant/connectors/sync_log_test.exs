defmodule Servant.Connectors.SyncLogTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.SyncLog
  alias Servant.Repo

  setup do
    user = user_fixture()

    {:ok, config} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "feed",
        "schedule" => "on_demand"
      })

    %{user: user, config: config}
  end

  test "a run keeps its counts; the list leaves its details out", %{config: config} do
    {:ok, log} = Connectors.create_sync_log(config.id)

    {:ok, _} =
      Connectors.complete_sync_log(log, %{
        entries_count: 2,
        fetched_count: 5,
        http_count: 3,
        http_failed_count: 1,
        log_count: 4,
        details: %{kinds: %{"note" => 5}}
      })

    assert [listed] = Connectors.list_sync_logs(config.id)
    assert listed.status == "completed"
    assert listed.fetched_count == 5
    assert listed.http_failed_count == 1
    assert listed.has_details
    refute Map.has_key?(listed, :details)

    assert Connectors.get_sync_log!(config.id, log.id).details == %{"kinds" => %{"note" => 5}}
  end

  test "details that cannot be stored are dropped, the run still closes", %{config: config} do
    {:ok, log} = Connectors.create_sync_log(config.id)

    assert {:ok, closed} =
             Connectors.fail_sync_log(log, "boom", %{
               http_count: 2,
               details: %{bad: {:not, :json}}
             })

    assert closed.status == "failed"
    assert closed.http_count == 2
    assert Repo.get!(SyncLog, log.id).details == nil
  end

  test "opening a run trims the history of its source", %{config: config} do
    now = DateTime.utc_now(:second)

    rows =
      for i <- 1..505 do
        %{
          id: Ecto.UUID.generate(),
          connector_config_id: config.id,
          status: "completed",
          details: %{"n" => i},
          started_at: DateTime.add(now, -i * 60, :second),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(SyncLog, rows)
    {:ok, _} = Connectors.create_sync_log(config.id)

    runs = where(SyncLog, connector_config_id: ^config.id)
    assert Repo.aggregate(runs, :count) == 500
    # The run just opened is one of the 50 most recent, and has no details yet.
    assert runs |> where([log], not is_nil(log.details)) |> Repo.aggregate(:count) == 49
  end

  test "a run belongs to its source", %{user: user, config: config} do
    {:ok, other} =
      Connectors.create_connector_config(user.id, %{
        "connector_type" => "rss",
        "name" => "other",
        "schedule" => "on_demand"
      })

    {:ok, log} = Connectors.create_sync_log(other.id)
    assert_raise Ecto.NoResultsError, fn -> Connectors.get_sync_log!(config.id, log.id) end
  end

  test "insert_run_entries/2 tells new entries from known ones", %{user: user} do
    entries = [
      %{"kind" => "note", "source" => "feed", "external_id" => "a", "title" => "A"},
      %{"kind" => "photo", "source" => "feed", "external_id" => "b", "title" => "B"}
    ]

    {:ok, 1} = Servant.Data.create_entries(user.id, [hd(entries)])
    {counts, details} = Connectors.insert_run_entries(user.id, entries)

    assert counts == %{entries_count: 1, fetched_count: 2}
    assert details.kinds == %{"note" => 1, "photo" => 1}
    assert [%{title: "B", kind: "photo"}] = details.new_entries
  end
end
