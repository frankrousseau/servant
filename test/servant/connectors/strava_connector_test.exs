defmodule Servant.Connectors.StravaConnectorTest do
  use ExUnit.Case, async: true

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
end
