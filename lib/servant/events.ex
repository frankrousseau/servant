defmodule Servant.Events do
  @moduledoc """
  Shared PubSub broadcasting for user-scoped data changes. Entry/note changes are
  published on the `"data:<user_id>"` topic and pushed to clients by
  `ServantWeb.DataChannel`. Kept in one place so the topic and semantics can't
  drift between contexts.
  """

  @doc "PubSub topic for a user's data changes."
  def topic(user_id), do: "data:#{user_id}"

  @doc "Broadcasts `message` to a user's data topic."
  def broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Servant.PubSub, topic(user_id), message)
  end
end
