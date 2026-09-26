defmodule Servant.Connectors.EVM.ExplorerTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EVM.Explorer

  describe "parse_body/1" do
    test "status 1 with a result list returns the transactions" do
      tx = %{"hash" => "0xabc", "blockNumber" => "123"}
      assert Explorer.parse_body(%{"status" => "1", "result" => [tx]}) == {:ok, [tx]}
    end

    test "status 0 with an empty result list is just no transactions" do
      body = %{"status" => "0", "message" => "No transactions found", "result" => []}
      assert Explorer.parse_body(body) == {:ok, []}
    end

    # Etherscan reports API errors as HTTP 200 + status "0" with the error in
    # result; these must surface as sync failures, not empty syncs (the V1
    # sunset went unnoticed for weeks because they were swallowed).
    test "status 0 with an error message in result is an error" do
      deprecated =
        "You are using a deprecated V1 endpoint, switch to Etherscan API V2 " <>
          "using https://docs.etherscan.io/v2-migration"

      body = %{"status" => "0", "message" => "NOTOK", "result" => deprecated}
      assert Explorer.parse_body(body) == {:error, deprecated}

      body = %{"status" => "0", "message" => "NOTOK", "result" => "Missing/Invalid API Key"}
      assert Explorer.parse_body(body) == {:error, "Missing/Invalid API Key"}
    end

    test "an unrecognized body shape is an error" do
      assert {:error, _} = Explorer.parse_body(%{"unexpected" => true})
    end
  end

  describe "list_transactions/3" do
    test "sends the Etherscan V2 parameters and returns the results" do
      tx = %{"hash" => "0xabc", "blockNumber" => "42"}

      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["module"] == "account"
        assert conn.params["action"] == "txlist"
        assert conn.params["address"] == "0xwallet"
        assert conn.params["startblock"] == "43"
        assert conn.params["chainid"] == "999"
        assert conn.params["apikey"] == "KEY"
        Req.Test.json(conn, %{"status" => "1", "result" => [tx]})
      end)

      assert {:ok, [^tx]} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api",
                 start_block: 43,
                 chain_id: 999,
                 api_key: "KEY"
               )
    end

    test "omits chainid and apikey when absent or blank (Blockscout)" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        refute Map.has_key?(conn.params, "chainid")
        refute Map.has_key?(conn.params, "apikey")
        Req.Test.json(conn, %{"status" => "1", "result" => []})
      end)

      assert {:ok, []} =
               Explorer.list_transactions("0xwallet", "https://blockscout.test/api", api_key: "")
    end

    test "retries an explorer rate-limit answer, then returns the results" do
      tx = %{"hash" => "0xabc", "blockNumber" => "42"}
      limited = "Max calls per sec rate limit reached (3/sec)"

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "0", "message" => "NOTOK", "result" => limited})
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "1", "result" => [tx]})
      end)

      assert {:ok, [^tx]} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api", api_key: "KEY")
    end

    test "does not retry other explorer errors" do
      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "status" => "0",
          "message" => "NOTOK",
          "result" => "Missing/Invalid API Key"
        })
      end)

      assert {:error, "Missing/Invalid API Key"} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api", api_key: "KEY")
    end

    test "follows pages until one comes back short" do
      full_page = for i <- 1..1000, do: %{"hash" => "0x#{i}", "blockNumber" => "#{i}"}

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "1"
        Req.Test.json(conn, %{"status" => "1", "result" => full_page})
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["page"] == "2"
        Req.Test.json(conn, %{"status" => "1", "result" => [%{"hash" => "0xlast"}]})
      end)

      assert {:ok, results} = Explorer.list_transactions("0xwallet", "https://explorer.test/api")
      assert length(results) == 1001
      assert List.last(results) == %{"hash" => "0xlast"}
    end

    test "retries a 429 and returns the retried response" do
      Req.Test.expect(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "1", "result" => [%{"hash" => "0xok"}]})
      end)

      assert {:ok, [%{"hash" => "0xok"}]} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api")
    end

    test "gives up after the retry budget on a transport error" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api")
    end

    test "a non-200 response is an error" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, %{status: 500}} =
               Explorer.list_transactions("0xwallet", "https://explorer.test/api")
    end

    test "keeps the pages already fetched when a later page fails" do
      full_page = for i <- 1..1000, do: %{"hash" => "0x#{i}"}

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "1", "result" => full_page})
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"status" => "0", "result" => "Query Timeout occured"})
      end)

      assert {:ok, results} = Explorer.list_transactions("0xwallet", "https://explorer.test/api")
      assert length(results) == 1000
    end
  end

  describe "list_token_transfers/3" do
    test "queries the tokentx action" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["action"] == "tokentx"
        Req.Test.json(conn, %{"status" => "1", "result" => []})
      end)

      assert {:ok, []} =
               Explorer.list_token_transfers("0xwallet", "https://explorer.test/api")
    end
  end
end
