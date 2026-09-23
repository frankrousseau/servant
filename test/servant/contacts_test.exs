defmodule Servant.ContactsTest do
  # SQLite: user inserts from two async modules collide ("Database busy"); keep serial.
  use Servant.DataCase, async: false

  import Ecto.Query

  alias Servant.Contacts
  alias Servant.Data
  alias Servant.Notes
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  defp user, do: Servant.Fixtures.user_fixture()

  defp contact(user_id, name, data \\ %{}) do
    Servant.Fixtures.entry_fixture(user_id, %{
      "kind" => "contact",
      "source" => "manual",
      "title" => name,
      "data" => Map.put(data, "display_name", name)
    })
  end

  defp entry(user_id, kind, title, data) do
    Servant.Fixtures.entry_fixture(user_id, %{
      "kind" => kind,
      "source" => "manual",
      "title" => title,
      "data" => data
    })
  end

  describe "merge_data/3" do
    test "survivor values win, blanks are filled, lists and tags are unioned" do
      survivor = %{
        "display_name" => "Alice Martin",
        "org" => "",
        "emails" => [%{"value" => "Alice@Example.com", "type" => "home"}],
        "phones" => [%{"value" => "+33 6 12 34 56 78", "type" => "cell"}],
        "tags" => ["family"],
        "note" => "met in Lyon"
      }

      duplicate = %{
        "display_name" => "A. Martin",
        "org" => "ACME",
        "emails" => [
          %{"value" => "alice@example.com", "type" => "work"},
          %{"value" => "alice@acme.test", "type" => "work"}
        ],
        "phones" => [
          %{"value" => "+33 (0)6 12 34 56 78", "type" => "home"},
          %{"value" => "", "type" => ""}
        ],
        "tags" => ["Family", "work"],
        "note" => "birthday in May",
        "carddav_vcf" => "BEGIN:VCARD..."
      }

      merged = Contacts.merge_data(survivor, [duplicate], ["s", "d"])

      assert merged["display_name"] == "Alice Martin"
      assert merged["org"] == "ACME"
      assert Enum.map(merged["emails"], & &1["value"]) == ["Alice@Example.com", "alice@acme.test"]
      # National and international spellings of one line count once.
      assert Enum.map(merged["phones"], & &1["value"]) == ["+33 6 12 34 56 78"]
      assert merged["tags"] == ["family", "work"]
      assert merged["note"] == "met in Lyon\n\nbirthday in May"
      refute Map.has_key?(merged, "carddav_vcf")
    end

    test "relations are unioned minus the ones pointing at a merged contact" do
      survivor = %{"relations" => [%{"contact_id" => "bob", "type" => "friend"}]}

      duplicate = %{
        "relations" => [
          %{"contact_id" => "bob", "type" => "colleague"},
          %{"contact_id" => "carol", "type" => "sibling"},
          %{"contact_id" => "s", "type" => "friend"}
        ]
      }

      merged = Contacts.merge_data(survivor, [duplicate], ["s", "d"])

      assert merged["relations"] == [
               %{"contact_id" => "bob", "type" => "friend"},
               %{"contact_id" => "carol", "type" => "sibling"}
             ]
    end
  end

  describe "merge/3" do
    test "keeps the survivor, deletes the duplicates and recomposes the title" do
      u = user()
      keep = contact(u.id, "Alice", %{"emails" => [%{"value" => "a@x.io", "type" => "home"}]})
      dup = contact(u.id, "Alice M.", %{"org" => "ACME"})

      assert {:ok, survivor} = Contacts.merge(u.id, keep.id, [dup.id])
      assert survivor.id == keep.id
      assert survivor.title == "Alice - ACME - a@x.io"
      assert survivor.data["org"] == "ACME"
      assert Repo.get(Data.Entry, dup.id) == nil
    end

    test "repoints events, photo faces and people, prefs, relations and note mentions" do
      u = user()
      keep = contact(u.id, "Alice")
      dup = contact(u.id, "Alice Martin")

      bob =
        contact(u.id, "Bob", %{"relations" => [%{"contact_id" => dup.id, "type" => "friend"}]})

      event = entry(u.id, "event", "Lunch", %{"contact_id" => dup.id})

      photo =
        entry(u.id, "photo", "IMG_1", %{
          "path" => "/files/x.jpg",
          "faces" => [%{"person_id" => dup.id, "person_name" => "Alice Martin", "box" => [1, 2]}],
          "people" => [
            %{"id" => dup.id, "name" => "Alice Martin"},
            %{"id" => keep.id, "name" => "Alice"}
          ]
        })

      birthdays = entry(u.id, "prefs", "birthdays", %{"contact_ids" => [dup.id, bob.id]})
      me = entry(u.id, "prefs", "me", %{"contact_id" => dup.id})

      {:ok, note} =
        Notes.create_note(u.id, %{"title" => "Trip", "body" => "with @[[Alice Martin]]"})

      assert [%NoteLink{target_note_id: target}] =
               Repo.all(from(l in NoteLink, where: l.source_note_id == ^note.id))

      assert target == dup.id

      assert {:ok, _} = Contacts.merge(u.id, keep.id, [dup.id])

      assert Repo.get!(Data.Entry, event.id).data["contact_id"] == keep.id

      photo = Repo.get!(Data.Entry, photo.id)

      assert [%{"person_id" => person_id, "person_name" => "Alice", "box" => [1, 2]}] =
               photo.data["faces"]

      assert person_id == keep.id
      assert photo.data["people"] == [%{"id" => keep.id, "name" => "Alice"}]

      assert Repo.get!(Data.Entry, birthdays.id).data["contact_ids"] == [keep.id, bob.id]
      assert Repo.get!(Data.Entry, me.id).data["contact_id"] == keep.id

      assert Repo.get!(Data.Entry, bob.id).data["relations"] == [
               %{"contact_id" => keep.id, "type" => "friend"}
             ]

      assert [%NoteLink{target_note_id: target}] =
               Repo.all(from(l in NoteLink, where: l.source_note_id == ^note.id))

      assert target == keep.id
      assert Enum.map(Notes.mentioning(u.id, keep.id), & &1.id) == [note.id]
    end

    test "a relation between the two merged contacts disappears" do
      u = user()
      keep = contact(u.id, "Alice", %{"relations" => []})

      dup =
        contact(u.id, "Alice M.", %{"relations" => [%{"contact_id" => "x", "type" => "friend"}]})

      {:ok, _} =
        Data.update_entry(u.id, keep.id, %{
          "data" =>
            Map.put(keep.data, "relations", [%{"contact_id" => dup.id, "type" => "sibling"}])
        })

      assert {:ok, survivor} = Contacts.merge(u.id, keep.id, [dup.id])
      assert survivor.data["relations"] == [%{"contact_id" => "x", "type" => "friend"}]
    end

    test "rejects bad requests without touching anything" do
      u = user()
      other = user()
      keep = contact(u.id, "Alice")
      dup = contact(u.id, "Alice M.")
      foreign = contact(other.id, "Alice")
      event = entry(u.id, "event", "Lunch", %{"contact_id" => dup.id})

      assert {:error, "at least one duplicate is required"} = Contacts.merge(u.id, keep.id, [])

      assert {:error, "the survivor cannot be one of the duplicates"} =
               Contacts.merge(u.id, keep.id, [dup.id, keep.id])

      assert {:error, "unknown contact"} = Contacts.merge(u.id, keep.id, [foreign.id])
      assert {:error, "unknown contact"} = Contacts.merge(u.id, foreign.id, [dup.id])
      assert {:error, "not a contact"} = Contacts.merge(u.id, keep.id, [event.id])
      assert {:error, "not a contact"} = Contacts.merge(u.id, event.id, [dup.id])

      assert Repo.get(Data.Entry, dup.id)
      assert Repo.get(Data.Entry, foreign.id)
    end
  end
end
