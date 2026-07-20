defmodule ServantWeb.EntryControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "index" do
    test "returns only the caller's entries with pagination meta", %{conn: conn, user: user} do
      entry_fixture(user.id, %{"title" => "Mine"})
      other = user_fixture()
      entry_fixture(other.id, %{"title" => "Theirs"})

      conn = get(conn, "/api/entries")
      assert %{"data" => data, "meta" => meta} = json_response(conn, 200)
      assert length(data) == 1
      assert hd(data)["title"] == "Mine"
      assert meta["total"] == 1
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/entries")
      assert json_response(conn, 401)
    end
  end

  describe "create" do
    test "201 with valid params", %{conn: conn} do
      conn =
        post(conn, "/api/entries", %{"kind" => "bookmark", "source" => "ui", "title" => "Hi"})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Hi"
      assert data["kind"] == "bookmark"
    end

    test "422 when creating a note (must use the notes API)", %{conn: conn} do
      conn = post(conn, "/api/entries", %{"kind" => "note", "source" => "ui", "title" => "Hi"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "422 when required fields are missing", %{conn: conn} do
      conn = post(conn, "/api/entries", %{"title" => "no kind/source"})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "delete_by_kind" do
    test "deletes all entries of the kind and returns the count", %{conn: conn, user: user} do
      entry_fixture(user.id, %{"kind" => "bookmark"})
      entry_fixture(user.id, %{"kind" => "bookmark"})
      keep = entry_fixture(user.id, %{"kind" => "photo"})

      conn = delete(conn, "/api/entries?kind=bookmark")
      assert json_response(conn, 200) == %{"deleted" => 2}
      remaining_ids = user.id |> Servant.Data.list_entries() |> Enum.map(& &1.id)
      assert remaining_ids == [keep.id]
    end

    test "400 without a kind param", %{conn: conn} do
      conn = delete(conn, "/api/entries?kind=")
      assert %{"error" => _} = json_response(conn, 400)
    end
  end

  describe "daily stats" do
    import Ecto.Query

    test "returns per-kind daily counts scoped to the caller, excluding old entries",
         %{conn: conn, user: user} do
      entry_fixture(user.id, %{"kind" => "photo"})
      entry_fixture(user.id, %{"kind" => "photo"})
      entry_fixture(user.id, %{"kind" => "bookmark"})

      old = entry_fixture(user.id, %{"kind" => "photo"})
      old_ts = NaiveDateTime.add(NaiveDateTime.utc_now(), -40, :day)

      Servant.Repo.update_all(
        from(e in Servant.Data.Entry, where: e.id == ^old.id),
        set: [inserted_at: old_ts]
      )

      other = user_fixture()
      entry_fixture(other.id, %{"kind" => "photo"})

      conn = get(conn, "/api/entries/stats/daily", %{"days" => "30"})
      assert %{"data" => data, "days" => 30} = json_response(conn, 200)

      today = Date.to_iso8601(Date.utc_today())
      assert data["photo"] == %{today => 2}
      assert data["bookmark"] == %{today => 1}
    end

    test "falls back to 30 days on invalid input", %{conn: conn} do
      conn = get(conn, "/api/entries/stats/daily", %{"days" => "nope"})
      assert %{"days" => 30} = json_response(conn, 200)
    end
  end

  describe "aggregate" do
    test "counts per local day in the requested timezone", %{conn: conn, user: user} do
      # 23:30 UTC is already the next day in Paris (UTC+2 in July)
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-07-10T23:30:00Z"})
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-07-10T12:00:00Z"})
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-07-11T08:00:00Z"})
      entry_fixture(user.id, %{"kind" => "bookmark", "occurred_at" => "2026-07-10T12:00:00Z"})
      other = user_fixture()
      entry_fixture(other.id, %{"kind" => "commit", "occurred_at" => "2026-07-10T12:00:00Z"})

      conn = get(conn, "/api/entries/aggregate", %{"kind" => "commit", "tz" => "Europe/Paris"})

      assert %{"data" => data, "agg" => "count", "bucket" => "day", "tz" => "Europe/Paris"} =
               json_response(conn, 200)

      assert data == [
               %{"bucket" => "2026-07-10", "value" => 1},
               %{"bucket" => "2026-07-11", "value" => 2}
             ]
    end

    test "sums a data field, counting missing values as zero", %{conn: conn, user: user} do
      entry_fixture(user.id, %{
        "kind" => "workout",
        "occurred_at" => "2026-07-10T10:00:00Z",
        "data" => %{"distance" => 5.5}
      })

      entry_fixture(user.id, %{
        "kind" => "workout",
        "occurred_at" => "2026-07-10T18:00:00Z",
        "data" => %{"distance" => 3}
      })

      entry_fixture(user.id, %{
        "kind" => "workout",
        "occurred_at" => "2026-07-11T10:00:00Z",
        "data" => %{"note" => "no distance"}
      })

      conn =
        get(conn, "/api/entries/aggregate", %{
          "kind" => "workout",
          "agg" => "sum",
          "field" => "distance",
          "tz" => "UTC"
        })

      assert %{"data" => data, "agg" => "sum"} = json_response(conn, 200)

      assert data == [
               %{"bucket" => "2026-07-10", "value" => 8.5},
               %{"bucket" => "2026-07-11", "value" => 0}
             ]
    end

    test "skips entries without occurred_at and defaults to the account timezone",
         %{conn: conn, user: user} do
      entry_fixture(user.id, %{"kind" => "bookmark"})
      entry_fixture(user.id, %{"kind" => "bookmark", "occurred_at" => "2026-07-10T12:00:00Z"})

      user |> Ecto.Changeset.change(timezone: "Europe/Paris") |> Servant.Repo.update!()

      conn = get(conn, "/api/entries/aggregate", %{"kind" => "bookmark"})
      assert %{"data" => data, "tz" => "Europe/Paris"} = json_response(conn, 200)
      assert data == [%{"bucket" => "2026-07-10", "value" => 1}]
    end

    test "400 on invalid parameters", %{conn: conn} do
      assert get(conn, "/api/entries/aggregate", %{"agg" => "avg"}) |> json_response(400)
      assert get(conn, "/api/entries/aggregate", %{"agg" => "sum"}) |> json_response(400)
      assert get(conn, "/api/entries/aggregate", %{"tz" => "Mars/Olympus"}) |> json_response(400)
      assert get(conn, "/api/entries/aggregate", %{"bucket" => "hour"}) |> json_response(400)
    end

    test "buckets by week, month and year", %{conn: conn, user: user} do
      # 2026-07-12 is a Sunday; its ISO week starts Monday 2026-07-06
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-07-12T10:00:00Z"})
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-07-06T10:00:00Z"})
      entry_fixture(user.id, %{"kind" => "commit", "occurred_at" => "2026-06-30T10:00:00Z"})

      week =
        get(conn, "/api/entries/aggregate", %{"kind" => "commit", "bucket" => "week"})
        |> json_response(200)

      assert week["bucket"] == "week"

      assert week["data"] == [
               %{"bucket" => "2026-06-29", "value" => 1},
               %{"bucket" => "2026-07-06", "value" => 2}
             ]

      month =
        get(conn, "/api/entries/aggregate", %{"kind" => "commit", "bucket" => "month"})
        |> json_response(200)

      assert month["data"] == [
               %{"bucket" => "2026-06", "value" => 1},
               %{"bucket" => "2026-07", "value" => 2}
             ]

      year =
        get(conn, "/api/entries/aggregate", %{"kind" => "commit", "bucket" => "year"})
        |> json_response(200)

      assert year["data"] == [%{"bucket" => "2026", "value" => 3}]
    end

    test "API tokens follow the list scope rules" do
      {conn, user} = register_and_log_in_api_token(build_conn(), ["app:trackers:read"])
      entry_fixture(user.id, %{"kind" => "tracker_log", "occurred_at" => "2026-07-10T12:00:00Z"})
      entry_fixture(user.id, %{"kind" => "bank_tx", "occurred_at" => "2026-07-10T12:00:00Z"})

      resp = get(conn, "/api/entries/aggregate", %{"kind" => "bank_tx"})
      assert json_response(resp, 403)["required"] == "app:finance:read"

      resp = get(conn, "/api/entries/aggregate", %{"tz" => "UTC"})
      assert json_response(resp, 200)["data"] == [%{"bucket" => "2026-07-10", "value" => 1}]
    end
  end

  describe "show / update / delete scoping" do
    test "shows the caller's own entry", %{conn: conn, user: user} do
      entry = entry_fixture(user.id, %{"title" => "Readable"})
      conn = get(conn, "/api/entries/#{entry.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == entry.id
    end

    test "404 when showing another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> get(conn, "/api/entries/#{foreign.id}") end)
    end

    test "updates the caller's own entry", %{conn: conn, user: user} do
      entry = entry_fixture(user.id, %{"title" => "Before"})
      conn = put(conn, "/api/entries/#{entry.id}", %{"title" => "After"})
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "After"
    end

    test "404 when updating another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> put(conn, "/api/entries/#{foreign.id}", %{"title" => "x"}) end)
    end

    test "refuses to update a note through the generic entries API", %{conn: conn, user: user} do
      {:ok, note} = Servant.Notes.create_note(user.id, %{"title" => "A note"})
      conn = put(conn, "/api/entries/#{note.id}", %{"title" => "hijacked"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "deletes the caller's own entry (204)", %{conn: conn, user: user} do
      entry = entry_fixture(user.id)
      conn = delete(conn, "/api/entries/#{entry.id}")
      assert response(conn, 204)
    end

    test "404 when deleting another user's entry", %{conn: conn} do
      other = user_fixture()
      foreign = entry_fixture(other.id)
      assert_error_sent(404, fn -> delete(conn, "/api/entries/#{foreign.id}") end)
    end
  end
end
