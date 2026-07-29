defmodule Servant.CardDAV.VCardTest do
  use ExUnit.Case, async: true

  alias Servant.CardDAV.VCard
  alias Servant.Data.Entry

  @vcf """
  BEGIN:VCARD
  VERSION:3.0
  UID:card-uid-1
  FN:Jeanne Dupont
  N:Dupont;Jeanne;;;
  ORG:CGWire
  TITLE:CTO
  EMAIL;TYPE=WORK:jeanne@example.com
  EMAIL;TYPE=HOME:jd@example.org
  TEL;TYPE=CELL:+33600000000
  ADR;TYPE=HOME:;;12 rue du Bac;Paris;;75007;France
  BDAY:1985-03-12
  NOTE:Une note\\, avec virgule
  END:VCARD
  """

  describe "parse_contact/1" do
    test "maps vCard fields onto the contact entry shape" do
      {:ok, parsed} = VCard.parse_contact(@vcf)

      assert parsed.uid == "card-uid-1"
      assert parsed.title == "Jeanne Dupont - CGWire - CTO - jeanne@example.com"
      assert parsed.birthday_at == ~U[1985-03-12 00:00:00Z]
      assert parsed.data["display_name"] == "Jeanne Dupont"
      assert parsed.data["org"] == "CGWire"
      assert parsed.data["title"] == "CTO"

      assert parsed.data["emails"] == [
               %{"value" => "jeanne@example.com", "type" => "work"},
               %{"value" => "jd@example.org", "type" => "home"}
             ]

      assert parsed.data["phones"] == [%{"value" => "+33600000000", "type" => "cell"}]
      assert parsed.data["address"] == "12 rue du Bac, Paris, 75007, France"
      assert parsed.data["note"] == "Une note, avec virgule"
    end

    test "rejects payloads without a vCard" do
      assert {:error, _} = VCard.parse_contact("nothing here")
    end
  end

  describe "to_vcf/1" do
    test "synthesizes a vCard 3.0 from entry fields" do
      entry = %Entry{
        id: "11111111-2222-3333-4444-555555555555",
        title: "Jeanne Dupont - CGWire",
        occurred_at: ~U[1985-03-12 00:00:00Z],
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: nil,
        data: %{
          "display_name" => "Jeanne Dupont",
          "org" => "CGWire",
          "emails" => [%{"value" => "jeanne@example.com", "type" => "work"}],
          "phones" => [%{"value" => "+33600000000", "type" => "other"}],
          "birthday" => "1985-03-12",
          "address" => "12 rue du Bac, Paris"
        }
      }

      vcf = VCard.to_vcf(entry)

      assert vcf =~ "UID:11111111-2222-3333-4444-555555555555@servant"
      assert vcf =~ "FN:Jeanne Dupont"
      assert vcf =~ "EMAIL;TYPE=WORK:jeanne@example.com"
      assert vcf =~ "TEL:+33600000000"
      assert vcf =~ "BDAY:1985-03-12"
      assert vcf =~ "ADR;TYPE=HOME:;;12 rue du Bac\\, Paris;;;;"
    end

    test "exports tags as CATEGORIES and relations as RELATED" do
      entry = %Entry{
        id: "11111111-2222-3333-4444-555555555555",
        title: "Jeanne Dupont",
        occurred_at: nil,
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: nil,
        data: %{
          "display_name" => "Jeanne Dupont",
          "tags" => ["family", "pa,ris", "", 42],
          "relations" => [
            %{"contact_id" => "c-bob", "type" => "sibling"},
            %{"contact_id" => "c-zoe", "type" => "climbing partner"},
            %{"contact_id" => "c-gone", "type" => "friend"},
            %{"type" => "friend"}
          ]
        }
      }

      names = %{"c-bob" => "Bob", "c-zoe" => "Zoé Martin"}
      vcf = VCard.to_vcf(entry, names: names)

      # Empty and non-string tags dropped; a comma inside a tag escaped so it
      # can't split the list.
      assert vcf =~ "CATEGORIES:family,pa\\,ris"
      assert vcf =~ "RELATED;TYPE=SIBLING;VALUE=text:Bob"
      # A type with a space can't be a bare param value.
      assert vcf =~ ~s(RELATED;TYPE="climbing partner";VALUE=text:Zoé Martin)
      # Unknown target and malformed relation are skipped.
      refute vcf =~ "c-gone"
      assert length(String.split(vcf, "RELATED")) == 3
    end

    test "carries no CATEGORIES or RELATED when there is nothing to export" do
      entry = %Entry{
        id: "id",
        title: "T",
        occurred_at: nil,
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: nil,
        data: %{"display_name" => "T", "tags" => [], "relations" => []}
      }

      vcf = VCard.to_vcf(entry)
      refute vcf =~ "CATEGORIES"
      refute vcf =~ "RELATED"
    end

    test "returns the stored raw vCard while the entry is untouched" do
      raw = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Raw\r\nEND:VCARD\r\n"

      entry = %Entry{
        id: "id",
        title: "T",
        occurred_at: ~U[2026-07-13 10:00:00Z],
        updated_at: ~U[2026-07-13 10:00:00Z],
        external_id: "abc",
        data: %{
          "display_name" => "T",
          "carddav_vcf" => raw,
          "carddav_vcf_at" => "2026-07-13T10:00:00Z"
        }
      }

      assert VCard.to_vcf(entry) == raw

      stale = %{entry | updated_at: ~U[2026-07-13 11:00:00Z]}
      regenerated = VCard.to_vcf(stale)
      assert regenerated =~ "BEGIN:VCARD"
      assert regenerated =~ "UID:abc"
    end
  end
end
