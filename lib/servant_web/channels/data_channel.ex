defmodule ServantWeb.DataChannel do
  use ServantWeb, :channel

  @impl true
  def join("data:" <> user_id, _payload, socket) do
    # User IDs are binary_id (UUID) strings, so compare directly — never coerce to integer.
    if socket.assigns.user_id == user_id do
      Phoenix.PubSub.subscribe(Servant.PubSub, "data:#{user_id}")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:entry_created, entry}, socket) do
    push(socket, "entry_change", %{type: "created", entry: entry_json(entry)})
    {:noreply, socket}
  end

  def handle_info({:entry_updated, entry}, socket) do
    push(socket, "entry_change", %{type: "updated", entry: entry_json(entry)})
    {:noreply, socket}
  end

  def handle_info({:entry_deleted, entry}, socket) do
    push(socket, "entry_change", %{type: "deleted", entry: %{id: entry.id}})
    {:noreply, socket}
  end

  # Aggregated signal for bulk inserts (connector syncs / imports): the client
  # should refetch rather than receive thousands of per-entry events.
  def handle_info({:entries_changed, payload}, socket) do
    push(socket, "entries_changed", payload)
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
