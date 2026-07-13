defmodule ServantWeb.ClientErrorControllerTest do
  use ServantWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  test "records a client error into the server error log", %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)

    log =
      capture_log(fn ->
        conn =
          post(conn, ~p"/api/client_errors", %{
            "context" => "upload",
            "message" => "IMG_1.heic: HEIC conversion timed out"
          })

        assert conn.status == 204
      end)

    assert log =~ "client error [upload]"
    assert log =~ user.id
    assert log =~ "HEIC conversion timed out"
  end

  test "requires authentication", %{conn: conn} do
    conn = post(conn, ~p"/api/client_errors", %{"message" => "x"})
    assert conn.status == 401
  end
end
