defmodule ServantWeb.AuditControllerTest do
  use ServantWeb.ConnCase

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  describe "system" do
    test "returns cpu, memory, server, workers and disk sections", %{conn: conn} do
      conn = get(conn, "/api/audit/system")
      assert %{"data" => data} = json_response(conn, 200)

      assert %{"cpu" => cpu, "memory" => _, "server" => server, "workers" => workers, "disk" => _} =
               data

      assert is_integer(cpu["cores"])
      assert is_integer(server["beam_memory_bytes"])
      assert is_integer(server["process_count"])
      assert is_list(workers)
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/audit/system")
      assert json_response(conn, 401)
    end
  end

  describe "logs" do
    test "returns access logs by default", %{conn: conn} do
      # This very request goes through the AccessLog plug, so after a second
      # call the first one must be visible in the buffer.
      get(conn, "/api/audit/logs")
      _ = :sys.get_state(Servant.Audit.LogBuffer)

      conn = get(conn, "/api/audit/logs")
      assert %{"data" => data} = json_response(conn, 200)
      assert is_list(data)
      assert Enum.any?(data, &(&1["path"] == "/api/audit/logs"))
    end

    test "returns error logs with type=error", %{conn: conn} do
      Servant.Audit.LogBuffer.record_error(%{at: "now", level: "error", message: "boom"})
      _ = :sys.get_state(Servant.Audit.LogBuffer)

      conn = get(conn, "/api/audit/logs?type=error")
      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.any?(data, &(&1["message"] == "boom"))
    end

    test "401 without a token" do
      conn = get(build_conn(), "/api/audit/logs")
      assert json_response(conn, 401)
    end
  end
end
