defmodule Servant.ApiTokensTest do
  use Servant.DataCase, async: true

  alias Servant.ApiTokens
  alias Servant.ApiTokens.ApiToken

  defp user, do: Servant.Fixtures.user_fixture()

  describe "create_token/2" do
    test "returns the struct and a srv_ plaintext, stores only the hash" do
      u = user()

      {:ok, token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["app:notes:read"]})

      assert String.starts_with?(plaintext, "srv_")
      assert token.prefix == String.slice(plaintext, 0, 8)
      assert token.token_hash != plaintext
      refute String.contains?(token.token_hash, plaintext)
      assert token.scopes == ["app:notes:read"]
    end

    test "rejects unknown scopes, empty scopes and missing name" do
      u = user()

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"name" => "x", "scopes" => ["notes:read"]})

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"name" => "x", "scopes" => []})

      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_token(u.id, %{"scopes" => ["data:read"]})
    end
  end

  describe "authenticate/1" do
    test "valid plaintext returns the user and scopes" do
      u = user()

      {:ok, _token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["data:read"]})

      assert {:ok, auth_user, ["data:read"]} = ApiTokens.authenticate(plaintext)
      assert auth_user.id == u.id
    end

    test "unknown, malformed and expired tokens fail" do
      u = user()
      assert ApiTokens.authenticate("srv_bogus") == :error
      assert ApiTokens.authenticate("not-a-token") == :error

      past = DateTime.add(DateTime.utc_now(:second), -60, :second)

      {:ok, _t, plaintext} =
        ApiTokens.create_token(u.id, %{
          "name" => "old",
          "scopes" => ["data:read"],
          "expires_at" => DateTime.to_iso8601(past)
        })

      assert ApiTokens.authenticate(plaintext) == :error
    end

    test "authenticate touches last_used_at" do
      u = user()

      {:ok, token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["data:read"]})

      assert token.last_used_at == nil
      {:ok, _, _} = ApiTokens.authenticate(plaintext)
      assert %DateTime{} = Repo.get!(ApiToken, token.id).last_used_at
    end

    test "authenticate debounces last_used_at within 60 seconds" do
      u = user()

      {:ok, token, plaintext} =
        ApiTokens.create_token(u.id, %{"name" => "agent", "scopes" => ["data:read"]})

      seeded = DateTime.add(DateTime.utc_now(:second), -30, :second)

      ApiToken
      |> where(id: ^token.id)
      |> Repo.update_all(set: [last_used_at: seeded])

      {:ok, _, _} = ApiTokens.authenticate(plaintext)

      assert Repo.get!(ApiToken, token.id).last_used_at == seeded
    end
  end

  describe "list_tokens/1 and delete_token/2" do
    test "lists own tokens only, deletes own token, revoked token stops working" do
      u1 = user()
      u2 = user()

      {:ok, t1, plaintext} =
        ApiTokens.create_token(u1.id, %{"name" => "a", "scopes" => ["data:read"]})

      {:ok, _t2, _} = ApiTokens.create_token(u2.id, %{"name" => "b", "scopes" => ["data:read"]})

      assert Enum.map(ApiTokens.list_tokens(u1.id), & &1.id) == [t1.id]

      # cannot delete someone else's token
      assert ApiTokens.delete_token(u2.id, t1.id) == {:error, :not_found}

      assert {:ok, _} = ApiTokens.delete_token(u1.id, t1.id)
      assert ApiTokens.authenticate(plaintext) == :error
    end
  end

  describe "agent_memory scope" do
    test "is a valid domain mapped to the agent_memory kind" do
      assert Servant.ApiTokens.Scopes.valid?("app:agent_memory:write")
      assert Servant.ApiTokens.Scopes.kind_domain("agent_memory") == "agent_memory"
      assert Servant.ApiTokens.Scopes.can_kind?(["app:agent_memory:read"], "agent_memory", :read)
      refute Servant.ApiTokens.Scopes.can_kind?(["app:notes:write"], "agent_memory", :read)
    end
  end
end
