defmodule Servant.Connectors.SolanaConnectorTest do
  use Servant.DataCase

  alias Servant.Connectors.SolanaConnector

  describe "init/2" do
    test "succeeds with valid wallet_address" do
      assert {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "abc123"})
      assert state.wallet_address == "abc123"
      assert state.min_lamports == 1_000_000
      assert state.last_signature == nil
    end

    test "accepts custom rpc_url and min_sol_amount" do
      config = %{
        "wallet_address" => "abc123",
        "rpc_url" => "https://my-rpc.example.com",
        "min_sol_amount" => 5_000_000
      }

      assert {:ok, state} = SolanaConnector.init(%{}, config)
      assert state.rpc_url == "https://my-rpc.example.com"
      assert state.min_lamports == 5_000_000
    end

    test "fails without wallet_address" do
      assert {:error, :missing_wallet_address} = SolanaConnector.init(%{}, %{})
    end

    test "accepts a .sol domain, resolution deferred to sync" do
      assert {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "frank.sol"})
      assert state.wallet_address == "frank.sol"
      assert state.resolved_address == nil
    end
  end

  describe "resolve_wallet/1" do
    test "plain address passes through without resolution" do
      {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => "abc123"})
      assert {:ok, resolved} = SolanaConnector.resolve_wallet(state)
      assert resolved.resolved_address == "abc123"
    end

    test "already-resolved state is returned as-is (no HTTP call)" do
      state = %{wallet_address: "frank.sol", resolved_address: "abc123"}
      assert {:ok, ^state} = SolanaConnector.resolve_wallet(state)
    end
  end

  describe "metadata" do
    test "id is solana" do
      assert SolanaConnector.id() == "solana"
    end

    test "kind is transaction" do
      assert SolanaConnector.kind() == "blockchain_tx"
    end

    test "does not support continuous schedule" do
      refute "continuous" in SolanaConnector.supported_schedules()
    end

    test "supports expected schedules" do
      schedules = SolanaConnector.supported_schedules()
      assert "on_demand" in schedules
      assert "every_5_minutes" in schedules
      assert "every_hour" in schedules
      assert "every_day" in schedules
      assert "every_week" in schedules
    end

    test "default schedule is every_5_minutes" do
      assert SolanaConnector.default_schedule() == "every_5_minutes"
    end
  end

  describe "sync/1" do
    @wallet "WaLLeTAddr1111111111111111111111111111111111"
    @peer "OtHeRAddr22222222222222222222222222222222222"

    defp sol_tx(signature) do
      %{
        "slot" => 200_000_000,
        "blockTime" => 1_700_000_000,
        "transaction" => %{
          "signatures" => [signature],
          "message" => %{
            "accountKeys" => [%{"pubkey" => @wallet}, %{"pubkey" => @peer}]
          }
        },
        "meta" => %{
          "err" => nil,
          "preBalances" => [2_000_000_000, 5_000_000_000],
          "postBalances" => [1_000_000_000, 6_000_000_000],
          "preTokenBalances" => [],
          "postTokenBalances" => []
        }
      }
    end

    # One stub for the full RPC conversation: the signatures first, then one
    # getTransaction for each signature.
    defp stub_rpc(signatures, transactions) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(raw)

        result =
          case request do
            %{"method" => "getSignaturesForAddress"} -> signatures
            %{"method" => "getTransaction", "params" => [sig | _]} -> transactions[sig]
          end

        Req.Test.json(conn, %{"result" => result})
      end)
    end

    defp state_for(wallet) do
      {:ok, state} = SolanaConnector.init(%{}, %{"wallet_address" => wallet})
      state
    end

    test "builds an entry per transaction, oldest first, and advances the cursor" do
      # getSignaturesForAddress returns the newest signatures first.
      stub_rpc(
        [%{"signature" => "sigNew", "err" => nil}, %{"signature" => "sigOld", "err" => nil}],
        %{"sigNew" => sol_tx("sigNew"), "sigOld" => sol_tx("sigOld")}
      )

      assert {:ok, [old, new], state} = SolanaConnector.sync(state_for(@wallet))

      assert old["external_id"] == "sigOld"
      assert new["external_id"] == "sigNew"
      assert old["kind"] == "blockchain_tx"
      assert old["source"] == "solana"
      assert old["title"] == "Sent 1 SOL to OtHe..2222"
      assert old["occurred_at"] == ~U[2023-11-14 22:13:20Z]
      assert old["data"]["wallet"] == @wallet
      assert old["data"]["counterparty"] == @peer

      assert state.last_signature == "sigNew"
      assert SolanaConnector.persisted_config(state) == %{"last_signature" => "sigNew"}
    end

    test "no signatures means no entries and an unchanged cursor" do
      stub_rpc([], %{})
      assert {:ok, [], %{last_signature: nil}} = SolanaConnector.sync(state_for(@wallet))
    end

    test "queries only what is newer than the persisted cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"params" => [@wallet, %{"until" => "sigSeen"}]} = Jason.decode!(raw)
        Req.Test.json(conn, %{"result" => []})
      end)

      {:ok, state} =
        SolanaConnector.init(%{}, %{
          "wallet_address" => @wallet,
          "last_signature" => "sigSeen"
        })

      assert {:ok, [], _state} = SolanaConnector.sync(state)
    end

    test "a failed transaction is skipped but still moves the cursor" do
      stub_rpc([%{"signature" => "sigFail", "err" => %{"InstructionError" => []}}], %{})

      assert {:ok, [], state} = SolanaConnector.sync(state_for(@wallet))
      assert state.last_signature == "sigFail"
    end

    test "a transaction the RPC no longer has is skipped" do
      stub_rpc([%{"signature" => "sigGone", "err" => nil}], %{"sigGone" => nil})

      assert {:ok, [], state} = SolanaConnector.sync(state_for(@wallet))
      assert state.last_signature == "sigGone"
    end

    # Regression: if the cursor advances past a transaction with a failed
    # fetch, the next sync skips it forever. The next sync only asks for newer
    # signatures.
    test "a fetch error halts the batch and leaves the cursor behind" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        case Jason.decode!(raw) do
          %{"method" => "getSignaturesForAddress"} ->
            signatures = [
              %{"signature" => "sigNew", "err" => nil},
              %{"signature" => "sigOld", "err" => nil}
            ]

            Req.Test.json(conn, %{"result" => signatures})

          %{"method" => "getTransaction"} ->
            Req.Test.json(conn, %{"error" => %{"code" => -32_004, "message" => "not available"}})
        end
      end)

      assert {:ok, [], state} = SolanaConnector.sync(state_for(@wallet))
      assert state.last_signature == nil
    end

    test "a signature listing failure fails the sync" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

      assert {:error, %{status: 500}, _state} = SolanaConnector.sync(state_for(@wallet))
    end

    test "resolves a .sol domain once, then queries the owner pubkey" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        if conn.method == "GET" do
          assert conn.request_path == "/resolve/frank.sol"
          Req.Test.json(conn, %{"s" => "ok", "result" => @wallet})
        else
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          assert %{"params" => [@wallet, _]} = Jason.decode!(raw)
          Req.Test.json(conn, %{"result" => []})
        end
      end)

      assert {:ok, [], state} = SolanaConnector.sync(state_for("frank.sol"))
      assert state.resolved_address == @wallet
    end

    test "an unresolvable .sol domain fails the sync" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"s" => "error", "result" => nil})
      end)

      state = state_for("nope.sol")
      assert {:error, {:sns_resolution_failed, _}, ^state} = SolanaConnector.sync(state)
    end

    test "SPL transfers get their symbol from the token list" do
      mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

      spl_tx = %{
        "slot" => 1,
        "blockTime" => 1_700_000_000,
        "transaction" => %{
          "signatures" => ["sigSpl"],
          "message" => %{"accountKeys" => [%{"pubkey" => @wallet}, %{"pubkey" => @peer}]}
        },
        "meta" => %{
          "err" => nil,
          "preBalances" => [1_000_000_000, 1],
          "postBalances" => [1_000_000_000, 1],
          "preTokenBalances" => [
            %{
              "owner" => @wallet,
              "mint" => mint,
              "uiTokenAmount" => %{"uiAmount" => 10.0, "decimals" => 6}
            }
          ],
          "postTokenBalances" => [
            %{
              "owner" => @wallet,
              "mint" => mint,
              "uiTokenAmount" => %{"uiAmount" => 5.0, "decimals" => 6}
            }
          ]
        }
      }

      Req.Test.stub(Servant.HTTP, fn conn ->
        if conn.method == "GET" do
          Req.Test.json(conn, [%{"address" => mint, "symbol" => "USDC", "name" => "USD Coin"}])
        else
          {:ok, raw, conn} = Plug.Conn.read_body(conn)

          result =
            case Jason.decode!(raw) do
              %{"method" => "getSignaturesForAddress"} ->
                [%{"signature" => "sigSpl", "err" => nil}]

              %{"method" => "getTransaction"} ->
                spl_tx
            end

          Req.Test.json(conn, %{"result" => result})
        end
      end)

      assert {:ok, [entry], _state} = SolanaConnector.sync(state_for(@wallet))
      assert [%{symbol: "USDC"}] = entry["data"]["transfers"]
      assert entry["title"] =~ "USDC"
    end
  end
end
