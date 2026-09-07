defmodule ServantWeb.UserSocketTest do
  use ServantWeb.ChannelCase

  alias Servant.Accounts
  alias ServantWeb.{Auth, Endpoint, UserSocket}

  defp token_for(user), do: Auth.sign_token(Endpoint, user)

  test "connects with a valid token and assigns the user" do
    user = user_fixture()

    assert {:ok, socket} = connect(UserSocket, %{"token" => token_for(user)})
    assert socket.assigns.user_id == user.id
    assert UserSocket.id(socket) == "user_socket:#{user.id}"
  end

  test "refuses a garbage token" do
    assert :error = connect(UserSocket, %{"token" => "not-a-token"})
  end

  test "refuses a connection without a token" do
    assert :error = connect(UserSocket, %{})
  end

  # The socket must not outlive a logout: sign_token embeds the token version,
  # and bumping it on the user invalidates every token already issued.
  test "refuses a token issued before the user's tokens were revoked" do
    user = user_fixture()
    token = token_for(user)

    {:ok, _user} = Accounts.bump_token_version(user)

    assert :error = connect(UserSocket, %{"token" => token})
  end

  test "refuses a token for a user that no longer exists" do
    user = user_fixture()
    token = token_for(user)
    Servant.Repo.delete!(user)

    assert :error = connect(UserSocket, %{"token" => token})
  end
end
