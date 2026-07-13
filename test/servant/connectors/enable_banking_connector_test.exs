defmodule Servant.Connectors.EnableBankingConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.EnableBankingConnector

  defp pem_key do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp valid_config do
    %{"application_id" => "app-123", "private_key" => pem_key(), "bank_name" => "CIC"}
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
end
