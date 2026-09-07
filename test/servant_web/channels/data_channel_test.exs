defmodule ServantWeb.DataChannelTest do
  use ServantWeb.ChannelCase

  alias Servant.Accounts
  alias Servant.Data

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        username: "channeluser",
        password: "password123",
        display_name: "Channel User"
      })

    # The socket carries the verified user id (a binary_id/UUID), exactly as
    # `ServantWeb.UserSocket.connect/3` assigns it after token verification.
    socket =
      Phoenix.ChannelTest.socket(ServantWeb.UserSocket, "user_socket:#{user.id}", %{
        user_id: user.id
      })

    %{user: user, socket: socket}
  end

  test "join succeeds on the owner's UUID topic", %{socket: socket, user: user} do
    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})
  end

  test "join is rejected for another user's topic", %{socket: socket} do
    other_id = Ecto.UUID.generate()

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "data:#{other_id}", %{})
  end

  test "pushes an entry_change event when an entry is created", %{socket: socket, user: user} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})

    {:ok, _entry} =
      Data.create_entry(user.id, %{
        "kind" => "bookmark",
        "source" => "test",
        "title" => "Hello"
      })

    assert_push "entry_change", %{type: "created", entry: %{title: "Hello"}}
  end

  test "pushes an entry_change event when an entry is deleted", %{socket: socket, user: user} do
    {:ok, entry} =
      Data.create_entry(user.id, %{"kind" => "bookmark", "source" => "test", "title" => "Bye"})

    {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})

    {:ok, _} = Data.delete_entry(user.id, entry.id)

    assert_push "entry_change", %{type: "deleted", entry: %{id: id}}
    assert id == entry.id
  end

  test "pushes an entry_change event when an entry is updated", %{socket: socket, user: user} do
    {:ok, entry} =
      Data.create_entry(user.id, %{"kind" => "bookmark", "source" => "test", "title" => "Before"})

    {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})

    {:ok, _updated} = Data.update_entry(user.id, entry.id, %{"title" => "After"})

    assert_push "entry_change", %{type: "updated", entry: %{title: "After"}}
  end

  # A connector sync inserting thousands of rows sends one aggregated signal
  # instead of one event per entry.
  test "pushes a single entries_changed signal for bulk inserts", %{socket: socket, user: user} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})

    entries =
      for i <- 1..3 do
        %{"kind" => "note", "source" => "fake", "title" => "Bulk #{i}"}
      end

    {:ok, 3} = Data.create_entries(user.id, entries)

    assert_push "entries_changed", %{count: 3}
    refute_push "entry_change", %{}
  end

  # Every socket only ever sees its owner's topic.
  test "another user's changes are never pushed", %{socket: socket, user: user} do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "data:#{user.id}", %{})

    other = user_fixture()

    {:ok, _entry} =
      Data.create_entry(other.id, %{"kind" => "bookmark", "source" => "test", "title" => "Theirs"})

    refute_push "entry_change", %{}
  end
end
