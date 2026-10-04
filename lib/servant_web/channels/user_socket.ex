defmodule ServantWeb.UserSocket do
  @moduledoc "Token-authenticated socket that carries the per-user data channel."

  use Phoenix.Socket

  channel "data:*", ServantWeb.DataChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Use the same path as HTTP auth (verify + token_version check). As a result,
    # the two cannot drift apart and a revoked token cannot open a socket.
    case ServantWeb.Auth.authenticate_token(socket, token) do
      {:ok, user} ->
        {:ok, assign(socket, :user_id, user.id)}

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    :error
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
