defmodule Servant.CardDAVTest do
  # SQLite: user inserts from two async modules collide ("Database busy"); keep serial.
  use Servant.DataCase, async: false

  alias Servant.CardDAV
  alias Servant.Data.Entry
  alias Servant.Repo

  @ios_vcf """
  BEGIN:VCARD\r
  VERSION:3.0\r
  N:Doe;John;;;\r
  FN:John Doe\r
  item1.TEL:01 23 45 67 89\r
  item1.X-ABLabel:_$!<Other>!$_\r
  UID:ios-uid\r
  END:VCARD\r
  """

  # The state a PUT left before the parser fix: the raw card is stored and
  # fresh, the parsed phone is missing.
  defp broken_contact(user_id) do
    {:ok, entry, :created} = CardDAV.put_contact(user_id, "ios.vcf", @ios_vcf)

    entry
    |> Entry.changeset(%{
      data:
        Map.merge(entry.data, %{
          "phones" => [],
          "carddav_vcf_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
        })
    })
    |> Repo.update!()
  end

  describe "backfill_parsed_fields/1" do
    test "fills the fields of a fresh raw card again" do
      user = Servant.Fixtures.user_fixture()
      entry = broken_contact(user.id)

      assert CardDAV.backfill_parsed_fields(user.id) == {1, 1}

      entry = Repo.get!(Entry, entry.id)
      assert entry.data["phones"] == [%{"value" => "01 23 45 67 89", "type" => "other"}]
      # The phone keeps getting its own card, not a synthesized one.
      assert CardDAV.VCard.to_vcf(entry) == @ios_vcf
      assert CardDAV.backfill_parsed_fields(user.id) == {0, 1}
    end

    test "leaves a contact edited in Servant since the PUT alone" do
      user = Servant.Fixtures.user_fixture()
      entry = broken_contact(user.id)

      entry
      |> Entry.changeset(%{
        data: Map.put(entry.data, "carddav_vcf_at", "2020-01-01T00:00:00Z")
      })
      |> Repo.update!()

      assert CardDAV.backfill_parsed_fields(user.id) == {0, 1}
      assert Repo.get!(Entry, entry.id).data["phones"] == []
    end
  end
end
