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
  end

  describe "import_vcard/2" do
    test "builds entries from vCard content" do
      {:ok, state} = VCardConnector.init(%{}, %{"source_name" => "Test"})
      {:ok, entries} = VCardConnector.import_vcard(@sample_vcf, state)

      assert length(entries) == 2
      [john, _] = entries

      assert john["kind"] == "contact"
      assert john["source"] == "vcard"
      assert john["external_id"] == "john-doe-123"
      assert String.contains?(john["title"], "John Doe")
      assert john["data"]["display_name"] == "John Doe"
      assert john["data"]["source_name"] == "Test"
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
