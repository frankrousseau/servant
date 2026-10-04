defmodule Servant.Events do
  @moduledoc """
  Shared PubSub broadcasting for user-scoped data changes. The module publishes
  the entry and note changes on the `"data:<user_id>"` topic, and
  `ServantWeb.DataChannel` pushes them to the clients. This code is in one
  place, so that the topic and the semantics cannot drift between contexts.
  """

  @doc "Returns the PubSub topic for the data changes of a user."
  def topic(user_id), do: "data:#{user_id}"

  @doc "Broadcasts `message` to the data topic of a user."
  def broadcast(user_id, message) do
    Phoenix.PubSub.broadcast(Servant.PubSub, topic(user_id), message)
  end
end
