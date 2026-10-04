defmodule Servant.Connectors.StravaConnectorTest do
  use Servant.DataCase

  alias Servant.Connectors
  alias Servant.Connectors.StravaConnector

  @valid %{
    "client_id" => "123",
    "client_secret" => "secret",
    "refresh_token" => "rt_1"
  }

  describe "init/2" do
    test "succeeds with client_id/secret/refresh_token" do
      assert {:ok, state} = StravaConnector.init(%{}, @valid)
      assert state.client_id == "123"
      assert state.refresh_token == "rt_1"
      assert state.last_activity_after == nil
    end

    test "carries a persisted last_activity_after cursor" do
      assert {:ok, state} =
               StravaConnector.init(%{}, Map.put(@valid, "last_activity_after", 1_700_000_000))

      assert state.last_activity_after == 1_700_000_000
    end

    test "requires each credential" do
      assert {:error, "client_id is required"} = StravaConnector.init(%{}, %{})

      assert {:error, "client_secret is required"} =
               StravaConnector.init(%{}, %{"client_id" => "1"})

      assert {:error, "refresh_token is required"} =
               StravaConnector.init(%{}, %{"client_id" => "1", "client_secret" => "s"})
    end
  end

  describe "persisted_config/1" do
    test "persists the (possibly rotated) refresh token and cursor" do
      state = %{refresh_token: "rt_2", last_activity_after: 1_700_000_500}

      assert StravaConnector.persisted_config(state) == %{
               "refresh_token" => "rt_2",
               "last_activity_after" => 1_700_000_500
             }
    end
  end

  describe "metadata" do
    test "id/kind and no continuous schedule" do
      assert StravaConnector.id() == "strava"
      assert StravaConnector.kind() == "activity"
      refute "continuous" in StravaConnector.supported_schedules()
    end
  end

  describe "sync/1" do
    defp activity(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => 42,
          "name" => "Morning Run",
          "sport_type" => "Run",
          "distance" => 10_500.0,
          "moving_time" => 3600,
          "start_date" => "2026-07-01T06:30:00Z"
        },
        overrides
      )
    end

    # One stub for the two hosts that the connector talks to: the OAuth token
    # endpoint (POST) and the activities endpoint (GET).
    defp stub_strava(opts) do
      token = Keyword.get(opts, :token, %{"access_token" => "at_1", "expires_at" => far_future()})
      activities = Keyword.get(opts, :activities, [])

      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.method do
          "POST" -> Req.Test.json(conn, token)
          "GET" -> Req.Test.json(conn, activities)
        end
      end)
    end

    defp far_future, do: DateTime.to_unix(DateTime.utc_now()) + 3600

    defp state do
      {:ok, state} = StravaConnector.init(%{}, @valid)
      state
    end

    test "refreshes the access token, caches it and builds entries" do
      stub_strava(activities: [activity()])

      assert {:ok, [entry], new_state} = StravaConnector.sync(state())

      assert entry["kind"] == "activity"
      assert entry["source"] == "strava"
      assert entry["external_id"] == "42"
      assert entry["title"] == "Morning Run"
      assert entry["occurred_at"] == ~U[2026-07-01 06:30:00Z]
      assert entry["data"]["distance_km"] == 10.5
      assert entry["metadata"]["strava_id"] == 42

      assert new_state.last_activity_after == 1_782_887_400

      assert %{"access_token" => "at_1"} = Connectors.get_env("strava", "tokens", "123")
    end

    test "a cached, still-valid token is reused without a refresh" do
      Connectors.put_env("strava", "tokens", "123", %{
        "access_token" => "cached",
        "expires_at" => far_future()
      })

      Req.Test.stub(Servant.HTTP, fn conn ->
        assert conn.method == "GET"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer cached"]
        Req.Test.json(conn, [])
      end)

      assert {:ok, [], _state} = StravaConnector.sync(state())
    end

    test "a token about to expire is refreshed" do
      Connectors.put_env("strava", "tokens", "123", %{
        "access_token" => "stale",
        "expires_at" => DateTime.to_unix(DateTime.utc_now()) + 60
      })

      stub_strava(activities: [])

      assert {:ok, [], _state} = StravaConnector.sync(state())
      assert %{"access_token" => "at_1"} = Connectors.get_env("strava", "tokens", "123")
    end

    # The rotated refresh token must survive a later failure. If not, the
    # connector authenticates with a token that Strava already invalidated.
    test "a rotated refresh token is kept even when the activity fetch fails" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.method do
          "POST" ->
            Req.Test.json(conn, %{
              "access_token" => "at_1",
              "expires_at" => far_future(),
              "refresh_token" => "rt_rotated"
            })

          "GET" ->
            Plug.Conn.send_resp(conn, 401, "nope")
        end
      end)

      assert {:error, message, new_state} = StravaConnector.sync(state())
      assert message =~ "Unauthorized"
      assert new_state.refresh_token == "rt_rotated"
      assert StravaConnector.persisted_config(new_state)["refresh_token"] == "rt_rotated"
    end

    test "a failed token refresh reports the API message" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"message" => "Bad Request"}))
      end)

      assert {:error, message, _state} = StravaConnector.sync(state())
      assert message == "Token refresh failed: Bad Request"
    end

    test "the rate limit is reported as such" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.method do
          "POST" -> Req.Test.json(conn, %{"access_token" => "at", "expires_at" => far_future()})
          "GET" -> Plug.Conn.send_resp(conn, 429, "slow down")
        end
      end)

      assert {:error, message, _state} = StravaConnector.sync(state())
      assert message =~ "rate limit"
    end

    test "paginates until a page comes back short" do
      full_page = for i <- 1..100, do: activity(%{"id" => i})

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"access_token" => "at", "expires_at" => far_future()})
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "1"
        assert conn.params["per_page"] == "100"
        Req.Test.json(conn, full_page)
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "2"
        Req.Test.json(conn, [activity(%{"id" => 101})])
      end)

      assert {:ok, entries, _state} = StravaConnector.sync(state())
      assert length(entries) == 101
    end

    test "only asks for activities newer than the cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.method do
          "POST" ->
            Req.Test.json(conn, %{"access_token" => "at", "expires_at" => far_future()})

          "GET" ->
            conn = Plug.Conn.fetch_query_params(conn)
            assert conn.params["after"] == "1700000000"
            Req.Test.json(conn, [])
        end
      end)

      {:ok, state} =
        StravaConnector.init(%{}, Map.put(@valid, "last_activity_after", 1_700_000_000))

      assert {:ok, [], %{last_activity_after: 1_700_000_000}} = StravaConnector.sync(state)
    end

    test "an activity without a name gets a generated title" do
      stub_strava(activities: [activity(%{"name" => nil})])

      assert {:ok, [entry], _state} = StravaConnector.sync(state())
      assert entry["title"] == "Run - 10.5 km in 60 min"
    end

    test "an activity with an unparsable date still yields an entry" do
      stub_strava(activities: [activity(%{"start_date" => "not-a-date"})])

      assert {:ok, [entry], new_state} = StravaConnector.sync(state())
      assert entry["occurred_at"]
      assert new_state.last_activity_after == nil
    end
  end
end
