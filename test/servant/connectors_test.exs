defmodule Servant.ConnectorsTest do
  use Servant.DataCase

  alias Servant.Accounts
  alias Servant.Connectors

  describe "persist_connector_cursor/2" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{
          username: "connuser",
          password: "password123",
          display_name: "Conn User"
        })

      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "solana",
          "name" => "My wallet",
          "config" => %{"wallet_address" => "abc", "min_sol_amount" => 1}
        })

      %{user: user, config: config}
    end

    test "merges the cursor into the stored config, preserving other keys", %{config: config} do
      assert {:ok, updated} =
               Connectors.persist_connector_cursor(config.id, %{"last_signature" => "sig123"})

      assert updated.config["last_signature"] == "sig123"
      assert updated.config["wallet_address"] == "abc"
      assert updated.config["min_sol_amount"] == 1
    end

    test "is a no-op for an empty cursor", %{config: config} do
      assert :ok = Connectors.persist_connector_cursor(config.id, %{})
    end

    test "is a no-op for an unknown config id" do
      assert :ok = Connectors.persist_connector_cursor(Ecto.UUID.generate(), %{"x" => 1})
    end
  end

  describe "config encryption at rest" do
    test "secrets are stored encrypted but read back decrypted" do
      user = user_fixture()

      {:ok, config} =
        Connectors.create_connector_config(user.id, %{
          "connector_type" => "strava",
          "name" => "s",
          "config" => %{"client_secret" => "supersecret", "wallet" => "public"}
        })

      {:ok, %{rows: [[raw]]}} =
        Servant.Repo.query("SELECT config FROM connector_configs WHERE id = ?", [config.id])

      assert Servant.Encrypted.encrypted?(raw)
      assert :binary.match(raw, "supersecret") == :nomatch

      reloaded = Connectors.get_connector_config!(user.id, config.id)
      assert reloaded.config["client_secret"] == "supersecret"
      assert reloaded.config["wallet"] == "public"
    end
  end

  describe "persisted_config/1" do
    test "solana persists last_signature" do
      assert Servant.Connectors.SolanaConnector.persisted_config(%{last_signature: "s"}) ==
               %{"last_signature" => "s"}
    end

    test "EVM-based connectors persist last_block" do
      assert Servant.Connectors.BaseConnector.persisted_config(%{last_block: 42}) ==
               %{"last_block" => 42}
    end

    test "strava persists the (possibly rotated) refresh_token and the activity cursor" do
      state = %{refresh_token: "r", last_activity_after: 123}

      assert Servant.Connectors.StravaConnector.persisted_config(state) ==
               %{"refresh_token" => "r", "last_activity_after" => 123}
    end

    test "a connector without a cursor persists nothing" do
      assert Servant.Connectors.RSSConnector.persisted_config(%{anything: 1}) == %{}
    end
  end

  describe "schedule_interval_ms/1" do
    alias Servant.Connectors.ConnectorConfig

    test "maps every supported schedule to an interval" do
      assert ConnectorConfig.schedule_interval_ms("every_5_minutes") == 300_000
      assert ConnectorConfig.schedule_interval_ms("every_hour") == 3_600_000
      assert ConnectorConfig.schedule_interval_ms("every_day") == 86_400_000
      assert ConnectorConfig.schedule_interval_ms("every_week") == 604_800_000
      # The worker floors this one, see Worker's @continuous_floor_ms
      assert ConnectorConfig.schedule_interval_ms("continuous") == 0
      assert ConnectorConfig.schedule_interval_ms("on_demand") == nil
    end

    test "an unknown schedule falls back to hourly instead of crashing a worker" do
      assert ConnectorConfig.schedule_interval_ms("every_fortnight") == 3_600_000
    end

    test "every schedule in all_schedules/0 is mapped" do
      for schedule <- ConnectorConfig.all_schedules() do
        assert ConnectorConfig.schedule_interval_ms(schedule) != nil or schedule == "on_demand"
      end
    end
  end

  describe "connector_modules/0" do
    test "every registered module implements the connector behaviour" do
      for {type, module} <- Connectors.connector_modules() do
        assert module.id() == type
        assert is_binary(module.name())
        assert is_binary(module.kind())
        assert module.default_schedule() in module.supported_schedules()

        assert Enum.all?(
                 module.supported_schedules(),
                 &(&1 in Servant.Connectors.ConnectorConfig.all_schedules())
               ),
               "#{type} declares a schedule the config schema rejects"
      end
    end
  end
end
