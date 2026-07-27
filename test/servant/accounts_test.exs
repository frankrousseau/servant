defmodule Servant.AccountsTest do
  use Servant.DataCase

  alias Servant.Accounts

  describe "authenticate_user/2 (BE-TEST-3)" do
    setup do
      user = user_fixture(%{"username" => "alice", "password" => "password123"})
      %{user: user}
    end

    test "succeeds with the right password", %{user: user} do
      assert {:ok, authed} = Accounts.authenticate_user("alice", "password123")
      assert authed.id == user.id
    end

    test "fails with a wrong password" do
      assert {:error, :invalid_credentials} = Accounts.authenticate_user("alice", "nope-wrong")
    end

    test "fails for an unknown user (and still runs a dummy verify)" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("ghost", "password123")
    end
  end

  describe "change_password/3 (BE-TEST-3)" do
    setup do
      %{user: user_fixture(%{"username" => "bob", "password" => "password123"})}
    end

    test "changes the password when the current one is correct", %{user: user} do
      assert {:ok, updated} = Accounts.change_password(user, "password123", "newpassword456")
      assert {:ok, _} = Accounts.authenticate_user("bob", "newpassword456")
      assert updated.hashed_password != user.hashed_password
    end

    test "rejects a wrong current password", %{user: user} do
      assert {:error, :wrong_password} =
               Accounts.change_password(user, "wrong-current", "newpassword456")
    end
  end

  describe "update_profile/2 theme" do
    setup do
      %{user: user_fixture(%{"username" => "themeuser", "password" => "password123"})}
    end

    test "defaults to night", %{user: user} do
      assert user.theme == "night"
    end

    test "accepts each known theme", %{user: user} do
      for theme <- ~w(night graphite day cyanotype sepia rosewood) do
        assert {:ok, updated} = Accounts.update_profile(user, %{"theme" => theme})
        assert updated.theme == theme
      end
    end

    test "rejects an unknown theme", %{user: user} do
      assert {:error, changeset} = Accounts.update_profile(user, %{"theme" => "solarized"})
      assert %{theme: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update_profile/2 enabled_apps" do
    setup do
      %{user: user_fixture(%{"username" => "appsuser", "password" => "password123"})}
    end

    test "defaults to nil (frontend default set)", %{user: user} do
      assert user.enabled_apps == nil
    end

    test "accepts a list of app ids", %{user: user} do
      ids = ["calendar", "files", "my-custom_app2"]
      assert {:ok, updated} = Accounts.update_profile(user, %{"enabled_apps" => ids})
      assert updated.enabled_apps == ids

      assert {:ok, cleared} = Accounts.update_profile(updated, %{"enabled_apps" => []})
      assert cleared.enabled_apps == []
    end

    test "rejects malformed ids", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_profile(user, %{"enabled_apps" => ["ok", "Not A Slug!"]})

      assert %{enabled_apps: ["must be a list of app ids"]} = errors_on(changeset)
    end
  end

  describe "update_profile/2 timezone" do
    setup do
      %{user: user_fixture(%{"username" => "tzuser", "password" => "password123"})}
    end

    test "defaults to UTC", %{user: user} do
      assert user.timezone == "UTC"
    end

    test "accepts a valid IANA timezone", %{user: user} do
      assert {:ok, updated} = Accounts.update_profile(user, %{"timezone" => "Europe/Paris"})
      assert updated.timezone == "Europe/Paris"
    end

    test "rejects a malformed timezone", %{user: user} do
      assert {:error, changeset} = Accounts.update_profile(user, %{"timezone" => "not a tz!"})
      assert %{timezone: ["must be a valid timezone"]} = errors_on(changeset)
    end
  end

  describe "ai_config" do
    test "defaults to disabled with the local base URL" do
      user = user_fixture()
      config = Accounts.ai_config(user)

      assert config["enabled"] == false
      assert config["base_url"] == "http://localhost:11434/v1"
      assert config["model"] == ""
      assert config["api_key"] == nil
      refute Accounts.ai_enabled?(user)
    end

    test "update_ai_config stores the config and ai_enabled? follows" do
      user = user_fixture()

      {:ok, user} =
        Accounts.update_ai_config(user, %{
          "enabled" => true,
          "model" => "qwen2.5-coder:14b",
          "api_key" => "sk-secret"
        })

      assert Accounts.ai_enabled?(user)
      assert Accounts.ai_config(user)["model"] == "qwen2.5-coder:14b"
      assert Accounts.ai_config(user)["api_key"] == "sk-secret"
    end

    test "keeps the stored key when given the mask, clears it on nil" do
      user = user_fixture()
      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret", "model" => "m"})

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "***", "model" => "m2"})
      assert Accounts.ai_config(user)["api_key"] == "sk-secret"
      assert Accounts.ai_config(user)["model"] == "m2"

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => nil})
      assert Accounts.ai_config(user)["api_key"] == nil
    end

    test "masked_ai_config hides the key" do
      user = user_fixture()
      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret"})

      assert Accounts.masked_ai_config(user)["api_key"] == "***"
      assert Accounts.masked_ai_config(user_fixture())["api_key"] == nil
    end

    test "rejects a non-http base_url and enabling without a model" do
      user = user_fixture()

      assert {:error, message} = Accounts.update_ai_config(user, %{"base_url" => "ftp://x"})
      assert message =~ "base_url"

      assert {:error, message} = Accounts.update_ai_config(user, %{"enabled" => true})
      assert message =~ "model"
    end

    test "trims a pasted key and stores nil when it trims to blank" do
      user = user_fixture()

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "  sk-x \n", "model" => "m"})
      assert Accounts.ai_config(user)["api_key"] == "sk-x"

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => " \n ", "model" => "m"})
      assert Accounts.ai_config(user)["api_key"] == nil
    end

    test "ignores a non-binary api_key and keeps the previous one" do
      user = user_fixture()
      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => "sk-secret", "model" => "m"})

      {:ok, user} = Accounts.update_ai_config(user, %{"api_key" => 123, "model" => "m2"})
      assert Accounts.ai_config(user)["api_key"] == "sk-secret"
      assert Accounts.ai_config(user)["model"] == "m2"
    end
  end
end
