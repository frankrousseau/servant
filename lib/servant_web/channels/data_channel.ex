defmodule ServantWeb.DataChannel do
  use ServantWeb, :channel

  @impl true
  def join("data:" <> user_id_str, _payload, socket) do
    user_id = String.to_integer(user_id_str)

    if socket.assigns.user_id == user_id do
      Phoenix.PubSub.subscribe(Servant.PubSub, "data:#{user_id}")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:entry_created, entry}, socket) do
    push(socket, "entry_created", entry_json(entry))
    {:noreply, socket}
  end

  def handle_info({:entry_updated, entry}, socket) do
    push(socket, "entry_updated", entry_json(entry))
    {:noreply, socket}
  end

  def handle_info({:entry_deleted, entry}, socket) do
    push(socket, "entry_deleted", %{id: entry.id})
    {:noreply, socket}
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      source: entry.source,
      external_id: entry.external_id,
      title: entry.title,
      occurred_at: entry.occurred_at,
      data: entry.data,
      metadata: entry.metadata
    }
  end
end
