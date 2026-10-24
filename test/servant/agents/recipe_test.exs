defmodule Servant.Agents.RecipeTest do
  use ExUnit.Case, async: true

  alias Servant.Agents.Recipe
  alias Servant.Data.Entry

  defp entry(attrs) do
    struct!(
      %Entry{title: nil, source: "test", occurred_at: nil, data: %{}, metadata: %{}},
      attrs
    )
  end

  defp dt(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  describe "validate/1" do
    test "accepts a full valid recipe" do
      recipe = %{
        "where" => [%{"field" => "data.category", "op" => "eq", "value" => "grocery"}],
        "group_by" => "data.category",
        "aggregate" => %{"op" => "sum", "field" => "data.amount"}
      }

      assert Recipe.validate(recipe) == :ok
    end

    test "accepts an empty recipe (digest of the window)" do
      assert Recipe.validate(%{}) == :ok
    end

    test "rejects non-maps and unknown keys" do
      assert {:error, _} = Recipe.validate("nope")
      assert {:error, message} = Recipe.validate(%{"select" => "x"})
      assert message =~ "unknown"
    end

    test "rejects bad where clauses" do
      assert {:error, _} = Recipe.validate(%{"where" => "not a list"})
      assert {:error, _} = Recipe.validate(%{"where" => [%{"field" => "data.x"}]})

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "password", "op" => "eq", "value" => 1}]
               })

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "explode", "value" => 1}]
               })

      # The numeric ops must have a numeric value. contains must have a string.
      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "gt", "value" => "high"}]
               })

      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "contains", "value" => 3}]
               })

      # exists takes no value.
      assert {:error, _} =
               Recipe.validate(%{
                 "where" => [%{"field" => "data.x", "op" => "exists", "value" => 1}]
               })

      assert Recipe.validate(%{"where" => [%{"field" => "data.x", "op" => "exists"}]}) == :ok
    end

    test "rejects bad group_by and aggregate" do
      assert {:error, _} = Recipe.validate(%{"group_by" => "year"})
      assert Recipe.validate(%{"group_by" => "week"}) == :ok
      assert Recipe.validate(%{"group_by" => "data.category"}) == :ok

      assert {:error, _} =
               Recipe.validate(%{"aggregate" => %{"op" => "median", "field" => "data.x"}})

      assert {:error, _} = Recipe.validate(%{"aggregate" => %{"op" => "sum"}})
      # count takes no field.
      assert {:error, _} =
               Recipe.validate(%{"aggregate" => %{"op" => "count", "field" => "data.x"}})

      assert Recipe.validate(%{"aggregate" => %{"op" => "count"}}) == :ok
    end

    test "emit_if requires an aggregate and no group_by, numeric value, comparison op" do
      agg = %{"aggregate" => %{"op" => "count"}}

      assert Recipe.validate(Map.put(agg, "emit_if", %{"op" => "eq", "value" => 0})) == :ok
      assert {:error, _} = Recipe.validate(%{"emit_if" => %{"op" => "eq", "value" => 0}})

      assert {:error, _} =
               Recipe.validate(
                 agg
                 |> Map.put("group_by", "data.x")
                 |> Map.put("emit_if", %{"op" => "eq", "value" => 0})
               )

      assert {:error, _} =
               Recipe.validate(Map.put(agg, "emit_if", %{"op" => "exists", "value" => 0}))

      assert {:error, _} =
               Recipe.validate(Map.put(agg, "emit_if", %{"op" => "eq", "value" => "zero"}))
    end
  end

  describe "run/2 filtering" do
    test "where conditions AND together; missing fields never match" do
      entries = [
        entry(data: %{"category" => "grocery", "amount" => 10}),
        entry(data: %{"category" => "grocery", "amount" => 3}),
        entry(data: %{"category" => "fuel", "amount" => 50}),
        entry(data: %{"amount" => 99})
      ]

      recipe = %{
        "where" => [
          %{"field" => "data.category", "op" => "eq", "value" => "grocery"},
          %{"field" => "data.amount", "op" => "gte", "value" => 5}
        ],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "1"
    end

    test "contains, neq and exists ops" do
      entries = [
        entry(title: "EDF invoice", data: %{"status" => "paid"}),
        entry(title: "Rent", data: %{})
      ]

      contains = %{
        "where" => [%{"field" => "title", "op" => "contains", "value" => "EDF"}],
        "aggregate" => %{"op" => "count"}
      }

      exists = %{
        "where" => [%{"field" => "data.status", "op" => "exists"}],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, c1} = Recipe.run(contains, entries)
      assert c1 =~ "1"
      assert {:ok, c2} = Recipe.run(exists, entries)
      assert c2 =~ "1"
    end

    test "occurred_at compares chronologically against ISO strings" do
      entries = [
        entry(occurred_at: dt("2026-07-01T00:00:00Z")),
        entry(occurred_at: dt("2026-07-15T00:00:00Z"))
      ]

      recipe = %{
        "where" => [%{"field" => "occurred_at", "op" => "gte", "value" => "2026-07-10"}],
        "aggregate" => %{"op" => "count"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "1"
    end
  end

  describe "run/2 aggregates" do
    test "sum, avg, min, max ignore non-numeric values" do
      entries = [
        entry(data: %{"amount" => 10}),
        entry(data: %{"amount" => 20}),
        entry(data: %{"amount" => "n/a"})
      ]

      assert {:ok, sum} =
               Recipe.run(%{"aggregate" => %{"op" => "sum", "field" => "data.amount"}}, entries)

      assert sum =~ "30"

      assert {:ok, avg} =
               Recipe.run(%{"aggregate" => %{"op" => "avg", "field" => "data.amount"}}, entries)

      assert avg =~ "15"

      assert {:ok, min} =
               Recipe.run(%{"aggregate" => %{"op" => "min", "field" => "data.amount"}}, entries)

      assert min =~ "10"

      assert {:ok, max} =
               Recipe.run(%{"aggregate" => %{"op" => "max", "field" => "data.amount"}}, entries)

      assert max =~ "20"
    end

    test "last takes the field from the most recent entry that has it" do
      entries = [
        entry(occurred_at: dt("2026-07-15T00:00:00Z"), data: %{}),
        entry(occurred_at: dt("2026-07-10T00:00:00Z"), data: %{"balance" => 1200}),
        entry(occurred_at: dt("2026-07-01T00:00:00Z"), data: %{"balance" => 900})
      ]

      assert {:ok, content} =
               Recipe.run(%{"aggregate" => %{"op" => "last", "field" => "data.balance"}}, entries)

      assert content =~ "1200"
    end

    test "sum over an empty selection is 0; avg reports no data" do
      assert {:ok, sum} = Recipe.run(%{"aggregate" => %{"op" => "sum", "field" => "data.x"}}, [])
      assert sum =~ "0"

      assert {:ok, avg} = Recipe.run(%{"aggregate" => %{"op" => "avg", "field" => "data.x"}}, [])
      assert avg =~ "no data"
    end
  end

  describe "run/2 grouping" do
    test "group by field renders a markdown table sorted by value desc" do
      entries = [
        entry(data: %{"category" => "grocery", "amount" => 10}),
        entry(data: %{"category" => "grocery", "amount" => 5}),
        entry(data: %{"category" => "fuel", "amount" => 50}),
        entry(data: %{"amount" => 1})
      ]

      recipe = %{
        "group_by" => "data.category",
        "aggregate" => %{"op" => "sum", "field" => "data.amount"}
      }

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "| data.category |"
      # fuel (50) comes before grocery (15). The entries without the group field go
      # under "-".
      {fuel_idx, _} = :binary.match(content, "fuel")
      {grocery_idx, _} = :binary.match(content, "grocery")
      assert fuel_idx < grocery_idx
      assert content =~ "| - |"
    end

    test "time buckets group on occurred_at and sort chronologically" do
      entries = [
        entry(occurred_at: dt("2026-07-15T10:00:00Z"), data: %{"amount" => 2}),
        entry(occurred_at: dt("2026-07-15T18:00:00Z"), data: %{"amount" => 3}),
        entry(occurred_at: dt("2026-06-01T00:00:00Z"), data: %{"amount" => 7})
      ]

      day = %{"group_by" => "day", "aggregate" => %{"op" => "sum", "field" => "data.amount"}}
      month = %{"group_by" => "month", "aggregate" => %{"op" => "sum", "field" => "data.amount"}}
      week = %{"group_by" => "week", "aggregate" => %{"op" => "count"}}

      assert {:ok, by_day} = Recipe.run(day, entries)
      assert by_day =~ "2026-07-15"
      assert by_day =~ "5"

      assert {:ok, by_month} = Recipe.run(month, entries)
      assert by_month =~ "2026-06"
      assert by_month =~ "2026-07"
      # Chronological order: the June row comes before the July row.
      {june_idx, _} = :binary.match(by_month, "2026-06")
      {july_idx, _} = :binary.match(by_month, "2026-07")
      assert june_idx < july_idx

      assert {:ok, by_week} = Recipe.run(week, entries)
      assert by_week =~ "2026-W29"
    end

    test "entries without occurred_at are skipped by time buckets" do
      entries = [entry(occurred_at: nil, data: %{"amount" => 5})]
      recipe = %{"group_by" => "day", "aggregate" => %{"op" => "count"}}

      assert {:ok, content} = Recipe.run(recipe, entries)
      assert content =~ "(no entries)"
    end
  end

  describe "run/2 digest and emit_if" do
    test "no aggregate renders a date | title list" do
      entries = [
        entry(occurred_at: dt("2026-07-18T09:00:00Z"), title: "Standup"),
        entry(occurred_at: nil, title: nil)
      ]

      assert {:ok, content} = Recipe.run(%{}, entries)
      assert content =~ "- 2026-07-18 | Standup"
      assert content =~ "- - | -"
    end

    test "empty digest says so" do
      assert {:ok, content} = Recipe.run(%{}, [])
      assert content =~ "(no entries)"
    end

    test "emit_if true produces content, emit_if false skips" do
      entries = [entry(data: %{})]
      base = %{"aggregate" => %{"op" => "count"}}

      assert {:ok, _} =
               Recipe.run(Map.put(base, "emit_if", %{"op" => "gte", "value" => 1}), entries)

      assert Recipe.run(Map.put(base, "emit_if", %{"op" => "eq", "value" => 0}), entries) == :skip
    end
  end
end
