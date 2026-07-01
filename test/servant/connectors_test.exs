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

  describe "config encryption at rest (BE-SEC-4)" do
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
end
