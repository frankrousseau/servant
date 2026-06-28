defmodule Servant.DataTest do
  use Servant.DataCase

  alias Servant.Data

  setup do
    user_a = user_fixture()
    user_b = user_fixture()

    a1 = entry_fixture(user_a.id, %{"kind" => "note", "source" => "a", "title" => "A1"})
    a2 = entry_fixture(user_a.id, %{"kind" => "photo", "source" => "a", "title" => "A2"})
    b1 = entry_fixture(user_b.id, %{"kind" => "note", "source" => "b", "title" => "B1"})

    %{user_a: user_a, user_b: user_b, a1: a1, a2: a2, b1: b1}
  end

  describe "user scoping (BE-TEST-2)" do
    test "list_entries only returns the caller's entries", %{user_a: a, b1: b1} do
      ids = a.id |> Data.list_entries() |> Enum.map(& &1.id)
      assert length(ids) == 2
      refute b1.id in ids
    end

    test "count_entries is per-user", %{user_a: a, user_b: b} do
      assert Data.count_entries(a.id) == 2
      assert Data.count_entries(b.id) == 1
    end

    test "stats are per-user", %{user_a: a, user_b: b} do
      assert Data.stats(a.id) == %{"note" => 1, "photo" => 1}
      assert Data.stats(b.id) == %{"note" => 1}
    end

    test "list_sources / list_kinds are per-user", %{user_a: a, user_b: b} do
      assert Enum.sort(Data.list_sources(a.id)) == ["a"]
      assert Enum.sort(Data.list_sources(b.id)) == ["b"]
      assert Enum.sort(Data.list_kinds(a.id)) == ["note", "photo"]
    end

    test "get_entry! cannot read another user's entry", %{user_a: a, b1: b1} do
      assert_raise Ecto.NoResultsError, fn -> Data.get_entry!(a.id, b1.id) end
    end

    test "update_entry cannot touch another user's entry", %{user_a: a, b1: b1} do
      assert_raise Ecto.NoResultsError, fn ->
        Data.update_entry(a.id, b1.id, %{"title" => "hacked"})
      end
    end

    test "delete_entry cannot delete another user's entry", %{user_a: a, b1: b1} do
      assert_raise Ecto.NoResultsError, fn -> Data.delete_entry(a.id, b1.id) end
      # B's entry still exists for B
      assert Data.get_entry!(b1.user_id, b1.id).id == b1.id
    end

    test "filters never cross the user boundary", %{user_a: a, a1: a1, b1: b1} do
      # B has a "note" too, but A's note filter must surface only A's.
      ids = a.id |> Data.list_entries(%{"kind" => "note"}) |> Enum.map(& &1.id)
      assert ids == [a1.id]
      refute b1.id in ids
    end
  end

  describe "create_entries/2 batch insert (BE-PERF-1)" do
    setup do
      %{user: user_fixture()}
    end

    test "inserts many in one call and returns the count", %{user: user} do
      rows =
        for n <- 1..3,
            do: %{
              "kind" => "note",
              "source" => "bulk",
              "external_id" => "e#{n}",
              "title" => "T#{n}"
            }

      assert {:ok, 3} = Data.create_entries(user.id, rows)
      assert Data.count_entries(user.id) == 3
    end

    test "dedupes on (user, source, external_id) via on_conflict", %{user: user} do
      dup = %{"kind" => "note", "source" => "bulk", "external_id" => "same", "title" => "x"}
      assert {:ok, 1} = Data.create_entries(user.id, [dup, dup])
      # re-running inserts nothing new
      assert {:ok, 0} = Data.create_entries(user.id, [dup])
      assert Data.count_entries(user.id) == 1
    end

    test "empty list is a no-op", %{user: user} do
      assert {:ok, 0} = Data.create_entries(user.id, [])
    end
  end
end
