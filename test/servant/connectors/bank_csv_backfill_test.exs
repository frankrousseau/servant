defmodule Servant.Connectors.BankCSVBackfillTest do
  # SQLite: user inserts from two async modules collide ("Database busy"); keep serial.
  use Servant.DataCase, async: false

  alias Servant.Connectors.BankCSVConnector
  alias Servant.Data.Entry
  alias Servant.Repo

  defp bank_tx(user_id, preset, currency, external_id) do
    Servant.Fixtures.entry_fixture(user_id, %{
      "kind" => "bank_tx",
      "source" => "bank_csv",
      "external_id" => external_id,
      "title" => "Paid 46.20 #{currency} - BLUE BOTTLE",
      "data" => %{
        "description" => "BLUE BOTTLE",
        "amount" => -46.2,
        "abs_amount" => 46.2,
        "currency" => currency,
        "direction" => "sent"
      },
      "metadata" => %{"import_source" => preset}
    })
  end

  test "relabels the N26 transactions stored under their original currency" do
    user = Servant.Fixtures.user_fixture()
    abroad = bank_tx(user.id, "n26", "USD", "a")
    euro = bank_tx(user.id, "n26", "EUR", "b")
    revolut = bank_tx(user.id, "revolut", "USD", "c")

    assert BankCSVConnector.backfill_n26_currency(user.id) == {1, 1}

    abroad = Repo.get!(Entry, abroad.id)
    assert abroad.title == "Paid 46.20 EUR - BLUE BOTTLE"
    assert abroad.data["currency"] == "EUR"
    assert abroad.data["original_currency"] == "USD"

    assert Repo.get!(Entry, euro.id).updated_at == euro.updated_at
    assert Repo.get!(Entry, revolut.id).data["currency"] == "USD"
    assert BankCSVConnector.backfill_n26_currency(user.id) == {0, 0}
  end
end
