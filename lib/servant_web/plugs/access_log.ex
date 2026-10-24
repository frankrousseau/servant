defmodule ServantWeb.Plugs.AccessLog do
  @moduledoc """
  Records each request into `Servant.Audit.LogBuffer` for the access-log tab of
  the Audit page. Static assets never reach this plug (`Plug.Static` halts
  first). The plug skips favicon-style noise explicitly.
  """

  @behaviour Plug

  alias Servant.Audit.LogBuffer

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start = System.monotonic_time(:microsecond)

    Plug.Conn.register_before_send(conn, fn conn ->
      unless skip?(conn.request_path) do
        LogBuffer.record_access(%{
          at: DateTime.to_iso8601(DateTime.utc_now()),
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          status: conn.status,
          duration_us: System.monotonic_time(:microsecond) - start,
          ip: format_ip(conn.remote_ip),
          user_id: user_id(conn)
        })
      end

      conn
    end)
  end

  defp skip?("/assets/" <> _), do: true
  defp skip?("/favicon" <> _), do: true
  defp skip?(_), do: false

  defp format_ip(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      chars -> List.to_string(chars)
    end
  end

  defp user_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp user_id(_), do: nil
end
