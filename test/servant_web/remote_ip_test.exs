defmodule ServantWeb.RemoteIpTest do
  use ServantWeb.ConnCase, async: true

  # The test conns arrive from 127.0.0.1, and RemoteIp treats that address as a
  # proxy. As a result, RemoteIp honors X-Forwarded-For, exactly as in the
  # documented nginx deployment.
  test "X-Forwarded-For from a loopback peer rewrites remote_ip", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> get(~p"/api/auth/config")

    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "remote_ip stays loopback without a forwarding header", %{conn: conn} do
    conn = get(conn, ~p"/api/auth/config")
    assert conn.remote_ip == {127, 0, 0, 1}
  end
end
