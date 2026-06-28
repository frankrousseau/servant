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
end
