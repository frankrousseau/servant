defmodule ServantWeb.AuditController do
  @moduledoc "System stats and log buffers backing the Audit page."

  use ServantWeb, :controller

  alias Servant.Audit
  alias Servant.Audit.LogBuffer

  def system(conn, _params) do
    json(conn, %{data: Audit.system_stats()})
  end

  def logs(conn, %{"type" => "error"}), do: json(conn, %{data: LogBuffer.error_logs()})
  def logs(conn, _params), do: json(conn, %{data: LogBuffer.access_logs()})
end
