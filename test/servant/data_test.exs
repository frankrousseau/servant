defmodule Servant.DataTest do
  use Servant.DataCase

  alias Servant.Data

  setup do
    user_a = user_fixture()
    user_b = user_fixture()

    a1 = entry_fixture(user_a.id, %{"kind" => "task", "source" => "a", "title" => "A1"})
    a2 = entry_fixture(user_a.id, %{"kind" => "photo", "source" => "a", "title" => "A2"})
    b1 = entry_fixture(user_b.id, %{"kind" => "task", "source" => "b", "title" => "B1"})

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
      assert Data.stats(a.id) == %{"task" => 1, "photo" => 1}
      assert Data.stats(b.id) == %{"task" => 1}
    end

    test "list_sources / list_kinds are per-user", %{user_a: a, user_b: b} do
      assert Enum.sort(Data.list_sources(a.id)) == ["a"]
      assert Enum.sort(Data.list_sources(b.id)) == ["b"]
      assert Enum.sort(Data.list_kinds(a.id)) == ["photo", "task"]
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

    test "delete_entries_by_kind removes only that kind for that user",
         %{user_a: a, user_b: b, a2: a2, b1: b1} do
      assert Data.delete_entries_by_kind(a.id, "task") == 1
      # A keeps the photo, B keeps their task.
      assert a.id |> Data.list_entries() |> Enum.map(& &1.id) == [a2.id]
      assert Data.get_entry!(b.id, b1.id).id == b1.id
      # Nothing left to delete: returns 0.
      assert Data.delete_entries_by_kind(a.id, "task") == 0
    end

    test "filters never cross the user boundary", %{user_a: a, a1: a1, b1: b1} do
      # B has a "task" too, but A's task filter must surface only A's.
      ids = a.id |> Data.list_entries(%{"kind" => "task"}) |> Enum.map(& &1.id)
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

  describe "q search filter" do
    test "matches title and JSON data substrings", %{user_a: a} do
      hit =
        entry_fixture(a.id, %{
          "kind" => "task",
          "source" => "a",
          "title" => "Groceries",
          "data" => %{"body" => "buy zorglub"}
        })

      assert a.id |> Data.list_entries(%{"q" => "grocer"}) |> Enum.map(& &1.id) == [hit.id]
      assert a.id |> Data.list_entries(%{"q" => "zorglub"}) |> Enum.map(& &1.id) == [hit.id]
      assert Data.list_entries(a.id, %{"q" => "no-such-thing"}) == []
    end

    test "combines with kind and stays user-scoped", %{user_a: a, user_b: b, a1: a1} do
      assert a.id |> Data.list_entries(%{"q" => "A1", "kind" => "task"}) |> Enum.map(& &1.id) ==
               [a1.id]

      assert a.id |> Data.list_entries(%{"q" => "A1", "kind" => "photo"}) |> Enum.map(& &1.id) ==
               []

      assert Data.list_entries(b.id, %{"q" => "A1"}) == []
    end

    test "blank q is ignored", %{user_a: a} do
      assert length(Data.list_entries(a.id, %{"q" => ""})) == 2
    end
  end
end
