defmodule Servant.Connectors.EnableBankingConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EnableBankingConnector

  # One key for the whole module: generating a 2048-bit RSA key per test made
  # this file the slowest in the suite.
  @pem_key :public_key.pem_encode([
             :public_key.pem_entry_encode(
               :RSAPrivateKey,
               :public_key.generate_key({:rsa, 2048, 65_537})
             )
           ])

  defp valid_config do
    %{"application_id" => "app-123", "private_key" => @pem_key, "bank_name" => "CIC"}
  end

  describe "init/2" do
    test "succeeds with application id and a valid PEM key" do
      assert {:ok, state} = EnableBankingConnector.init(%{}, valid_config())
      assert state.application_id == "app-123"
      assert state.country == "FR"
      assert state.session_id == nil
      assert state.cursors == %{}
    end

    test "requires each credential and a decodable key" do
      assert {:error, "application_id is required"} = EnableBankingConnector.init(%{}, %{})

      assert {:error, "private_key is required"} =
               EnableBankingConnector.init(%{}, %{"application_id" => "app"})

      assert {:error, "private_key is not a valid PEM RSA key"} =
               EnableBankingConnector.init(%{}, %{
                 "application_id" => "app",
                 "private_key" => "not a pem"
               })
    end

    test "carries the persisted session and cursors" do
      config =
        Map.merge(valid_config(), %{
          "session_id" => "sess-1",
          "accounts" => [%{"uid" => "acc-1", "name" => "CCP"}],
          "valid_until" => "2026-10-01T00:00:00Z",
          "cursors" => %{"acc-1" => "2026-07-10"}
        })

      assert {:ok, state} = EnableBankingConnector.init(%{}, config)
      assert state.session_id == "sess-1"
      assert [%{"uid" => "acc-1"}] = state.accounts
      assert state.cursors == %{"acc-1" => "2026-07-10"}
    end
  end

  describe "sync/1 preconditions" do
    test "asks to connect when there is no session" do
      {:ok, state} = EnableBankingConnector.init(%{}, valid_config())
      assert {:error, message, ^state} = EnableBankingConnector.sync(state)
      assert message =~ "Not connected"
    end

    test "asks to reconnect when the consent expired" do
      config =
        Map.merge(valid_config(), %{
          "session_id" => "sess-1",
          "valid_until" => "2026-01-01T00:00:00Z"
        })

      {:ok, state} = EnableBankingConnector.init(%{}, config)
      assert {:error, message, ^state} = EnableBankingConnector.sync(state)
      assert message =~ "consent expired"
    end
  end

  describe "jwt/1" do
    test "produces an RS256 JWT with the application id as kid" do
      {:ok, state} = EnableBankingConnector.init(%{}, valid_config())

      assert [header, payload, signature] = String.split(EnableBankingConnector.jwt(state), ".")

      decoded_header = header |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert decoded_header["alg"] == "RS256"
      assert decoded_header["kid"] == "app-123"

      decoded_payload = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert decoded_payload["aud"] == "api.enablebanking.com"
      assert decoded_payload["exp"] > decoded_payload["iat"]

      assert byte_size(Base.url_decode64!(signature, padding: false)) == 256
    end
  end

  describe "build_entry/3" do
    @tx %{
      "entry_reference" => "ref-42",
      "status" => "BOOK",
      "booking_date" => "2026-07-10",
      "credit_debit_indicator" => "DBIT",
      "transaction_amount" => %{"currency" => "EUR", "amount" => "45.67"},
      "balance_after_transaction" => %{"currency" => "EUR", "amount" => "1234.56"},
      "creditor" => %{"name" => "EDF"},
      "remittance_information" => ["PRLV EDF", "FACTURE 123"]
    }

    test "maps a debit to a sent bank_tx entry" do
      entry = EnableBankingConnector.build_entry(@tx, "acc-1", "CCP")

      assert entry["kind"] == "bank_tx"
      assert entry["source"] == "enable_banking"
      assert entry["title"] == "Paid 45.67 EUR - PRLV EDF - FACTURE 123"
      assert entry["occurred_at"] == ~U[2026-07-10 12:00:00Z]
      assert entry["data"]["amount"] == -45.67
      assert entry["data"]["direction"] == "sent"
      assert entry["data"]["balance"] == 1234.56
      assert entry["data"]["account"] == "CCP"
      assert entry["data"]["counterparty"] == "EDF"
    end

    test "maps a credit and falls back to the counterparty for the description" do
      tx =
        @tx
        |> Map.put("credit_debit_indicator", "CRDT")
        |> Map.put("remittance_information", [])
        |> Map.put("debtor", %{"name" => "CPAM"})

      entry = EnableBankingConnector.build_entry(tx, "acc-1", "CCP")
      assert entry["data"]["direction"] == "received"
      assert entry["data"]["amount"] == 45.67
      assert entry["data"]["description"] == "CPAM"
    end

    test "external ids are deterministic and account-scoped" do
      a = EnableBankingConnector.build_entry(@tx, "acc-1", "CCP")
      b = EnableBankingConnector.build_entry(@tx, "acc-1", "CCP")
      c = EnableBankingConnector.build_entry(@tx, "acc-2", "Autre")

      assert a["external_id"] == b["external_id"]
      refute a["external_id"] == c["external_id"]
    end
  end

  describe "metadata" do
    test "id/kind and no continuous schedule" do
      assert EnableBankingConnector.id() == "enable_banking"
      assert EnableBankingConnector.kind() == "bank_tx"
      refute "continuous" in EnableBankingConnector.supported_schedules()
    end
  end

  describe "sync/1" do
    defp connected_config(overrides \\ %{}) do
      valid_config()
      |> Map.merge(%{
        "session_id" => "sess-1",
        "accounts" => [%{"uid" => "acc-1", "name" => "CCP"}],
        "valid_until" => "2099-01-01T00:00:00Z"
      })
      |> Map.merge(overrides)
    end

    defp connected_state(overrides \\ %{}) do
      {:ok, state} = EnableBankingConnector.init(%{}, connected_config(overrides))
      state
    end

    defp transaction(overrides \\ %{}) do
      Map.merge(
        %{
          "entry_reference" => "ref-1",
          "booking_date" => "2026-07-10",
          "credit_debit_indicator" => "DBIT",
          "transaction_amount" => %{"amount" => "12.34", "currency" => "EUR"},
          "remittance_information" => ["Boulangerie"]
        },
        overrides
      )
    end

    test "fetches each account's transactions and records a cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        assert conn.request_path == "/accounts/acc-1/transactions"
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["transaction_status"] == "BOOK"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert String.contains?(jwt, ".")

        Req.Test.json(conn, %{
          "transactions" => [
            transaction(),
            transaction(%{"entry_reference" => "ref-2", "booking_date" => "2026-07-12"})
          ]
        })
      end)

      assert {:ok, entries, state} = EnableBankingConnector.sync(connected_state())

      assert length(entries) == 2
      assert hd(entries)["kind"] == "bank_tx"
      assert hd(entries)["data"]["account"] == "CCP"
      assert state.cursors == %{"acc-1" => "2026-07-12"}

      assert EnableBankingConnector.persisted_config(state) == %{
               "cursors" => %{"acc-1" => "2026-07-12"}
             }
    end

    # Banks book transactions late, so the refetch starts a week behind the
    # cursor and lets the entries upsert dedup the overlap.
    test "refetches a week behind the stored cursor" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["date_from"] == "2026-07-03"
        Req.Test.json(conn, %{"transactions" => []})
      end)

      state = connected_state(%{"cursors" => %{"acc-1" => "2026-07-10"}})
      assert {:ok, [], new_state} = EnableBankingConnector.sync(state)
      assert new_state.cursors == %{"acc-1" => "2026-07-10"}
    end

    test "follows the continuation key" do
      Req.Test.expect(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{
          "transactions" => [transaction()],
          "continuation_key" => "next-page"
        })
      end)

      Req.Test.expect(Servant.HTTP, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["continuation_key"] == "next-page"
        Req.Test.json(conn, %{"transactions" => [transaction(%{"entry_reference" => "ref-2"})]})
      end)

      assert {:ok, entries, _state} = EnableBankingConnector.sync(connected_state())
      assert length(entries) == 2
    end

    test "a single failing account fails the whole sync" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end)

      assert {:error, message, _state} = EnableBankingConnector.sync(connected_state())
      assert message =~ "Unauthorized"
    end

    test "a revoked consent asks for a reconnect" do
      Req.Test.stub(Servant.HTTP, fn conn -> Plug.Conn.send_resp(conn, 403, "revoked") end)

      assert {:error, message, _state} = EnableBankingConnector.sync(connected_state())
      assert message =~ "reconnect"
    end

    # One account down must not silently amputate the sync: the others still
    # produce entries and the failure is logged.
    test "keeps the accounts that did sync when another one fails" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/accounts/acc-1/transactions" ->
            Req.Test.json(conn, %{"transactions" => [transaction()]})

          "/accounts/acc-2/transactions" ->
            Plug.Conn.send_resp(conn, 410, "gone")
        end
      end)

      state =
        connected_state(%{
          "accounts" => [
            %{"uid" => "acc-1", "name" => "CCP"},
            %{"uid" => "acc-2", "name" => "Savings"}
          ]
        })

      assert {:ok, [entry], new_state} = EnableBankingConnector.sync(state)
      assert entry["data"]["account"] == "CCP"
      assert Map.keys(new_state.cursors) == ["acc-1"]
    end

    test "an unexpected payload is an error, not a crash" do
      Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, message, _state} = EnableBankingConnector.sync(connected_state())
      assert message =~ "unexpected transactions payload"
    end

    test "an account without a name falls back to its IBAN" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        Req.Test.json(conn, %{"transactions" => [transaction()]})
      end)

      state =
        connected_state(%{
          "accounts" => [%{"uid" => "acc-1", "account_id" => %{"iban" => "FR7612345"}}]
        })

      assert {:ok, [entry], _state} = EnableBankingConnector.sync(state)
      assert entry["data"]["account"] == "FR7612345"
    end
  end

  describe "auth_url/3" do
    defp stub_aspsps(aspsps, auth_response \\ %{"url" => "https://bank.test/consent"}) do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/aspsps" ->
            conn = Plug.Conn.fetch_query_params(conn)
            assert conn.params["country"] == "FR"
            Req.Test.json(conn, %{"aspsps" => aspsps})

          "/auth" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            body = Jason.decode!(raw)
            assert body["redirect_url"] == "https://app.test/callback"
            assert body["state"] == "config-1"
            assert body["access"]["transactions"] == true
            assert body["aspsp"] == %{"name" => "CIC", "country" => "FR"}
            Req.Test.json(conn, auth_response)
        end
      end)
    end

    test "returns the bank's consent URL" do
      stub_aspsps([%{"name" => "CIC"}])

      assert {:ok, "https://bank.test/consent"} =
               EnableBankingConnector.auth_url(
                 connected_config(),
                 "https://app.test/callback",
                 "config-1"
               )
    end

    test "caps the requested consent at the bank's maximum" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        case conn.request_path do
          "/aspsps" ->
            Req.Test.json(conn, %{
              "aspsps" => [%{"name" => "CIC", "maximum_consent_validity" => 86_400}]
            })

          "/auth" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            valid_until = Jason.decode!(raw)["access"]["valid_until"]
            {:ok, requested, _} = DateTime.from_iso8601(valid_until)
            assert DateTime.diff(requested, DateTime.utc_now()) <= 86_400
            Req.Test.json(conn, %{"url" => "https://bank.test/consent"})
        end
      end)

      assert {:ok, _url} =
               EnableBankingConnector.auth_url(connected_config(), "https://app.test/cb", "c1")
    end

    test "needs a bank name" do
      config = Map.delete(connected_config(), "bank_name")

      assert {:error, message} =
               EnableBankingConnector.auth_url(config, "https://app.test/cb", "c1")

      assert message =~ "bank_name is required"
    end

    test "an unknown bank suggests close matches" do
      stub_aspsps([%{"name" => "CIC Est"}, %{"name" => "Crédit Mutuel"}])

      config = Map.put(connected_config(), "bank_name", "CIC")

      assert {:error, message} =
               EnableBankingConnector.auth_url(config, "https://app.test/cb", "c1")

      assert message =~ "not found in FR"
      assert message =~ "CIC Est"
    end

    test "a bank list of an unexpected shape is reported" do
      Req.Test.stub(Servant.HTTP, fn conn -> Req.Test.json(conn, %{"oops" => true}) end)

      assert {:error, message} =
               EnableBankingConnector.auth_url(connected_config(), "https://app.test/cb", "c1")

      assert message =~ "unexpected bank list"
    end

    test "a consent response without a URL is reported" do
      stub_aspsps([%{"name" => "CIC"}], %{"no_url" => true})

      assert {:error, message} =
               EnableBankingConnector.auth_url(
                 connected_config(),
                 "https://app.test/callback",
                 "config-1"
               )

      assert message =~ "no authorization URL"
    end
  end

  describe "exchange_code/2" do
    test "turns the code into the session fields to persist" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        assert conn.request_path == "/sessions"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"code" => "auth-code"}

        Req.Test.json(conn, %{
          "session_id" => "sess-9",
          "access" => %{"valid_until" => "2026-12-01T00:00:00Z"},
          "accounts" => [
            %{
              "uid" => "acc-1",
              "name" => "CCP",
              "account_id" => %{"iban" => "FR76"},
              "currency" => "EUR",
              "ignored" => "field"
            }
          ]
        })
      end)

      assert {:ok, fields} = EnableBankingConnector.exchange_code(valid_config(), "auth-code")

      assert fields["session_id"] == "sess-9"
      assert fields["valid_until"] == "2026-12-01T00:00:00Z"
      assert fields["cursors"] == %{}
      assert [account] = fields["accounts"]

      assert account == %{
               "uid" => "acc-1",
               "name" => "CCP",
               "account_id" => %{"iban" => "FR76"},
               "currency" => "EUR"
             }
    end

    test "a rejected code is reported" do
      Req.Test.stub(Servant.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"message" => "Invalid code"}))
      end)

      assert {:error, message} = EnableBankingConnector.exchange_code(valid_config(), "bad")
      assert message =~ "Invalid code"
    end

    test "a bad config never reaches the API" do
      assert {:error, "application_id is required"} =
               EnableBankingConnector.exchange_code(%{}, "code")
    end
  end
end
