defmodule Mix.Tasks.Servant.SeedTest do
  # System.put_env on the storage roots: keep serial.
  use Servant.DataCase, async: false

  import Ecto.Query
  import Servant.Fixtures

  alias Servant.Data.Entry
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  setup do
    base = Path.join(System.tmp_dir!(), "servant-seed-#{System.unique_integer([:positive])}")
    System.put_env("FILES_DIR", Path.join(base, "files"))
    System.put_env("TMP_DIR", Path.join(base, "tmp"))

    on_exit(fn ->
      System.delete_env("FILES_DIR")
      System.delete_env("TMP_DIR")
      File.rm_rf(base)
    end)

    %{user: user_fixture()}
  end

  test "seeds every app's kinds for the user", %{user: user} do
    counts = Mix.Tasks.Servant.Seed.seed(user, photos: 2)

    kinds =
      Repo.all(
        from entry in Entry,
          where: entry.user_id == ^user.id,
          group_by: entry.kind,
          select: {entry.kind, count(entry.id)}
      )
      |> Map.new()

    for kind <- ~w(contact event calendar note checklist tracker tracker_log
                   account bank_tx balance prefs invoice article file photo
                   agent_memory commit activity) do
      assert Map.get(kinds, kind, 0) > 0, "no #{kind} entry seeded"
    end

    # Notes went through the Notes context: their wikilinks are in the graph.
    assert Repo.aggregate(from(link in NoteLink, where: link.user_id == ^user.id), :count) > 0

    # Connectors exist with a sync history, but stay on demand: seeded fake
    # credentials must never reach a real API.
    connectors =
      Repo.all(
        from config in Servant.Connectors.ConnectorConfig, where: config.user_id == ^user.id
      )

    assert length(connectors) >= 5
    assert Enum.all?(connectors, &(&1.enabled and &1.schedule == "on_demand"))
    assert Repo.aggregate(Servant.Connectors.SyncLog, :count) > 0

    # Relations form a network: a contact keeps every link written to it.
    most_relations =
      from(entry in Entry, where: entry.user_id == ^user.id and entry.kind == "contact")
      |> Repo.all()
      |> Enum.map(&length(&1.data["relations"] || []))
      |> Enum.max()

    assert most_relations >= 3

    # Photos went through the real pipeline: the blob and its thumbnail exist.
    photo = Repo.one!(from entry in Entry, where: entry.kind == "photo", limit: 1)
    assert %{"path" => "/files/" <> relative, "thumb_path" => "/files/" <> _thumb} = photo.data
    assert {:ok, _absolute} = Servant.Storage.resolve_owned_path(user.id, relative)

    # The summary reports at least the transaction volume it inserted.
    assert counts["finance entries"] > 100
  end
end
