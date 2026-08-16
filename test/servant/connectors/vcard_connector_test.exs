defmodule Servant.Connectors.VCardConnectorTest do
  use ExUnit.Case, async: true

  alias Servant.Connectors.VCardConnector

  @sample_vcf """
  BEGIN:VCARD
  VERSION:3.0
  FN:John Doe
  N:Doe;John;;;
  EMAIL;TYPE=WORK:john@example.com
  EMAIL;TYPE=HOME:john.doe@gmail.com
  TEL;TYPE=CELL:+33612345678
  TEL;TYPE=WORK:+33112345678
  ORG:Acme Corp
  TITLE:Engineer
  BDAY:1990-05-15
  URL:https://johndoe.com
  NOTE:A good friend
  UID:john-doe-123
  END:VCARD
  BEGIN:VCARD
  VERSION:4.0
  FN:Jane Smith
  N:Smith;Jane;;;
  EMAIL:jane@example.com
  TEL:+33698765432
  END:VCARD
  """

  @photo_vcf """
  BEGIN:VCARD
  VERSION:3.0
  FN:Photo Owner
  PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRgABAQ==
  UID:photo-1
  END:VCARD
  """

  describe "parse_vcards/1" do
    test "parses multiple vCards" do
      contacts = VCardConnector.parse_vcards(@sample_vcf)
      assert length(contacts) == 2
    end

    test "extracts display name from FN" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert john.display_name == "John Doe"
    end

    test "extracts typed emails" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert length(john.emails) == 2
      assert Enum.any?(john.emails, &(&1["value"] == "john@example.com" and &1["type"] == "work"))

      assert Enum.any?(
               john.emails,
               &(&1["value"] == "john.doe@gmail.com" and &1["type"] == "home")
             )
    end

    test "extracts typed phones" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert length(john.phones) == 2
      assert Enum.any?(john.phones, &(&1["value"] == "+33612345678" and &1["type"] == "cell"))
    end

    test "extracts org, title, url, note, birthday" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert john.org == "Acme Corp"
      assert john.title == "Engineer"
      assert john.url == "https://johndoe.com"
      assert john.note == "A good friend"
      assert john.birthday == "1990-05-15"
    end

    test "uses UID as external ID" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert john.uid == "john-doe-123"
    end

    test "falls back to display_name for UID when missing" do
      [_, jane] = VCardConnector.parse_vcards(@sample_vcf)
      assert jane.uid == "Jane Smith"
    end

    test "reads an inline photo, folded over several lines" do
      vcf =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Photo Owner\r\nPHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQ\r\n SkZJRgABAQ==\r\nEND:VCARD"

      [contact] = VCardConnector.parse_vcards(vcf)
      assert contact.photo == "/9j/4AAQSkZJRgABAQ=="
    end

    test "reads a vCard 4.0 data URI photo" do
      vcf =
        "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Photo Owner\r\nPHOTO:data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ==\r\nEND:VCARD"

      [contact] = VCardConnector.parse_vcards(vcf)
      assert contact.photo == "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ=="
    end

    test "is nil when the card carries no photo" do
      [john | _] = VCardConnector.parse_vcards(@sample_vcf)
      assert john.photo == nil
    end
  end

  describe "import_vcard/2" do
    test "builds entries from vCard content" do
      {:ok, state} = VCardConnector.init(%{}, %{"source_name" => "Test"})
      {:ok, entries} = VCardConnector.import_vcard(@sample_vcf, state)

      assert length(entries) == 2
      [john, _] = entries

      assert john["kind"] == "contact"
      assert john["external_id"] == "john-doe-123"
      assert String.contains?(john["title"], "John Doe")
      assert john["data"]["display_name"] == "John Doe"
      assert john["data"]["source_name"] == "Test"
    end

    test "imports as manual contacts, the source CardDAV exposes" do
      {:ok, state} = VCardConnector.init(%{}, %{})
      {:ok, entries} = VCardConnector.import_vcard(@sample_vcf, state)

      assert Enum.all?(entries, &(&1["source"] == "manual"))
    end

    test "keeps each card verbatim so a phone gets its extras back" do
      {:ok, state} = VCardConnector.init(%{}, %{})
      {:ok, [john, jane]} = VCardConnector.import_vcard(@sample_vcf, state)

      assert john["data"]["carddav_vcf"] =~ "FN:John Doe"
      assert john["data"]["carddav_vcf"] =~ "UID:john-doe-123"
      refute john["data"]["carddav_vcf"] =~ "Jane Smith"
      assert {:ok, _, _} = DateTime.from_iso8601(john["data"]["carddav_vcf_at"])
      assert jane["data"]["carddav_vcf"] =~ "FN:Jane Smith"
    end

    test "keeps a photo in the raw card, which no synthesized card carries" do
      {:ok, state} = VCardConnector.init(%{}, %{})
      {:ok, [contact]} = VCardConnector.import_vcard(@photo_vcf, state)

      assert contact["data"]["carddav_vcf"] =~ "PHOTO;ENCODING=b;TYPE=JPEG:/9j/4AAQSkZJRgABAQ=="
    end

    test "leaves the avatar alone when the importer has no user to store it for" do
      {:ok, state} = VCardConnector.init(%{}, %{})
      {:ok, [contact]} = VCardConnector.import_vcard(@photo_vcf, state)

      refute Map.has_key?(contact["data"], "photo")
    end
  end

  describe "parse_vcards_with_raw/1" do
    test "pairs every contact with its own card" do
      pairs = VCardConnector.parse_vcards_with_raw(@sample_vcf)

      assert [{john, john_raw}, {jane, jane_raw}] = pairs
      assert john.display_name == "John Doe"
      assert john_raw =~ "BEGIN:VCARD"
      assert john_raw =~ "END:VCARD"
      assert jane.display_name == "Jane Smith"
      assert jane_raw =~ "FN:Jane Smith"
    end

    test "keeps the original folding in the raw card" do
      vcf =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nNOTE:This is a long\r\n  note that wraps\r\nUID:fold-test\r\nEND:VCARD"

      assert [{contact, raw}] = VCardConnector.parse_vcards_with_raw(vcf)
      assert contact.note == "This is a long note that wraps"
      assert raw =~ "NOTE:This is a long\r\n  note that wraps"
    end

    test "drops a card left without its END line" do
      assert [] = VCardConnector.parse_vcards_with_raw("BEGIN:VCARD\r\nFN:Truncated\r\n")
    end
  end

  describe "init/2" do
    test "succeeds without url (import-only)" do
      assert {:ok, state} = VCardConnector.init(%{}, %{})
      assert state.url == nil
    end

    test "accepts url and source_name" do
      assert {:ok, state} =
               VCardConnector.init(%{}, %{
                 "url" => "https://x.com/c.vcf",
                 "source_name" => "iCloud"
               })

      assert state.url == "https://x.com/c.vcf"
      assert state.source_name == "iCloud"
    end
  end

  describe "metadata" do
    test "id is vcard" do
      assert VCardConnector.id() == "vcard"
    end

    test "kind is contact" do
      assert VCardConnector.kind() == "contact"
    end

    test "default schedule is on_demand" do
      assert VCardConnector.default_schedule() == "on_demand"
    end
  end

  describe "line unfolding" do
    test "handles folded lines in vCard" do
      vcf =
        "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test\r\nNOTE:This is a long\r\n  note that wraps\r\nUID:fold-test\r\nEND:VCARD"

      [contact] = VCardConnector.parse_vcards(vcf)
      assert contact.note == "This is a long note that wraps"
    end
  end
end
