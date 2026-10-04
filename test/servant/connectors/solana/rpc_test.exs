defmodule Servant.Connectors.Solana.RPCTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.Solana.RPC

  test "posts a JSON-RPC envelope and unwraps the result" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "getBalance"
      assert body["params"] == ["wallet"]
      Req.Test.json(conn, %{"jsonrpc" => "2.0", "result" => 42})
    end)

    assert RPC.call("getBalance", ["wallet"]) == {:ok, 42}
  end

  test "uses the configured rpc_url" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      assert conn.host == "my-rpc.example.com"
      Req.Test.json(conn, %{"result" => nil})
    end)

    assert RPC.call("getBalance", [], rpc_url: "https://my-rpc.example.com") == {:ok, nil}
  end

  test "an RPC-level error is returned" do
    error = %{"code" => -32_602, "message" => "Invalid param"}
    Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"error" => error}) end)

    assert RPC.call("getTransaction", ["bad"]) == {:error, error}
  end

  # The public RPC nodes answer 200 with a 429 error object. The client must
  # retry this answer and not report it as a permanent failure.
  test "retries a rate limit reported inside a 200 body" do
    Req.Test.expect(Servant.HTTP, fn conn ->
      Req.Test.json(conn, %{"error" => %{"code" => 429, "message" => "Too many requests"}})
    end)

    Req.Test.expect(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"result" => "ok"}) end)

    assert RPC.call("getBalance", ["wallet"]) == {:ok, "ok"}
  end

  test "an HTTP error is returned once the retries are exhausted" do
    Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert {:error, %{status: 503}} = RPC.call("getBalance", ["wallet"])
  end

  describe "get_signatures/2" do
    test "passes the pagination cursors through" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"params" => ["wallet", config]} = Jason.decode!(raw)
        assert config == %{"limit" => 10, "before" => "sigB", "until" => "sigU"}
        Req.Test.json(conn, %{"result" => []})
      end)

      assert RPC.get_signatures("wallet", limit: 10, before: "sigB", until: "sigU") == {:ok, []}
    end

    test "defaults to a page of 100 and omits absent cursors" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"params" => ["wallet", %{"limit" => 100} = config]} = Jason.decode!(raw)
        assert map_size(config) == 1
        Req.Test.json(conn, %{"result" => []})
      end)

      assert RPC.get_signatures("wallet") == {:ok, []}
    end
  end

  test "get_transaction/2 asks for the parsed encoding" do
    Req.Test.stub(Servant.HTTP, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert %{"method" => "getTransaction", "params" => ["sig", opts]} = Jason.decode!(raw)
      assert opts["encoding"] == "jsonParsed"
      assert opts["maxSupportedTransactionVersion"] == 0
      Req.Test.json(conn, %{"result" => nil})
    end)

    assert RPC.get_transaction("sig") == {:ok, nil}
  end
end
