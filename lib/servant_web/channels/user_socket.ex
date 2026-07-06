defmodule ServantWeb.UserSocket do
  @moduledoc "Token-authenticated socket carrying the per-user data channel."

  use Phoenix.Socket

  channel "data:*", ServantWeb.DataChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Same salt/max-age as HTTP auth: delegate so the two can't drift.
    case ServantWeb.Auth.verify_token(socket, token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    :error
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
