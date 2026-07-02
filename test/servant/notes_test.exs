defmodule Servant.NotesTest do
  use Servant.DataCase

  import Ecto.Query

  alias Servant.Notes
  alias Servant.Notes.NoteLink
  alias Servant.Repo

  setup do
    %{user: user_fixture(), other: user_fixture()}
  end

  describe "create_note/2" do
    test "stores a note as an entry with kind/source and a derived slug", %{user: user} do
      {:ok, note} =
        Notes.create_note(user.id, %{
          "title" => "Idées",
          "folder" => "Projets/Servant",
          "body" => "# Hello"
        })

      assert note.kind == "note"
      assert note.source == "notes"
      assert note.title == "Idées"
      assert note.external_id == "projets/servant/idées"
      assert note.data["body"] == "# Hello"
      assert note.data["folder"] == "Projets/Servant"
    end

    test "defaults folder to root and parses tags from the body", %{user: user} do
      {:ok, note} =
        Notes.create_note(user.id, %{"title" => "Loose", "body" => "todo #idea #servant"})

      assert note.external_id == "loose"
      assert note.data["folder"] == ""
      assert Enum.sort(note.data["tags"]) == ["idea", "servant"]
    end

    test "rejects a duplicate title in the same folder with a title error", %{user: user} do
      {:ok, _} = Notes.create_note(user.id, %{"title" => "Dup", "body" => ""})

      assert {:error, changeset} = Notes.create_note(user.id, %{"title" => "dup ", "body" => ""})
      assert %{title: [message]} = errors_on(changeset)
      assert message =~ "already exists"

      # Same title in another folder is a different slug, so it is fine.
      assert {:ok, _} = Notes.create_note(user.id, %{"title" => "Dup", "folder" => "Sub"})
    end
  end

  describe "wikilinks and backlinks" do
    test "create maintains note_links and resolves backlinks", %{user: user} do
      {:ok, target} = Notes.create_note(user.id, %{"title" => "Target", "body" => ""})

      {:ok, source} =
        Notes.create_note(user.id, %{"title" => "Source", "body" => "see [[Target]] please"})

      backlinks = Notes.backlinks(user.id, target)
      assert Enum.map(backlinks, & &1.id) == [source.id]

      # The target note has no inbound links.
      assert Notes.backlinks(user.id, source) == []
    end

    test "links to a not-yet-created note resolve once it is created", %{user: user} do
      {:ok, source} = Notes.create_note(user.id, %{"title" => "A", "body" => "links [[B]]"})
      {:ok, target} = Notes.create_note(user.id, %{"title" => "B", "body" => ""})

      assert Enum.map(Notes.backlinks(user.id, target), & &1.id) == [source.id]
    end

    test "update_note recomputes outgoing links", %{user: user} do
      {:ok, b} = Notes.create_note(user.id, %{"title" => "B", "body" => ""})
      {:ok, c} = Notes.create_note(user.id, %{"title" => "C", "body" => ""})
      {:ok, a} = Notes.create_note(user.id, %{"title" => "A", "body" => "[[B]]"})

      assert Enum.map(Notes.backlinks(user.id, b), & &1.id) == [a.id]

      {:ok, _a} = Notes.update_note(user.id, a.id, %{"title" => "A", "body" => "now [[C]]"})

      assert Notes.backlinks(user.id, b) == []
      assert Enum.map(Notes.backlinks(user.id, c), & &1.id) == [a.id]
    end

    test "renaming a note un-resolves links that pointed at its old title", %{user: user} do
      {:ok, source} = Notes.create_note(user.id, %{"title" => "A", "body" => "see [[B]]"})
      {:ok, b} = Notes.create_note(user.id, %{"title" => "B", "body" => ""})

      link = Repo.one!(from l in NoteLink, where: l.source_note_id == ^source.id)
      assert link.target_note_id == b.id

      {:ok, renamed} = Notes.update_note(user.id, b.id, %{"title" => "B2"})

      link = Repo.one!(from l in NoteLink, where: l.source_note_id == ^source.id)
      assert link.target_note_id == nil
      assert Notes.backlinks(user.id, renamed) == []
    end

    test "[[folder/title]] links resolve too", %{user: user} do
      {:ok, target} =
        Notes.create_note(user.id, %{"title" => "Spec", "folder" => "Docs", "body" => ""})

      {:ok, source} =
        Notes.create_note(user.id, %{"title" => "Index", "body" => "ref [[Docs/Spec]]"})

      assert Enum.map(Notes.backlinks(user.id, target), & &1.id) == [source.id]
    end
  end

  describe "parse_wikilinks/1 and parse_tags/1" do
    test "extracts unique canonical wikilink targets" do
      assert Notes.parse_wikilinks("[[One]] and [[ Two ]] and [[one]]") == ["one", "two"]
    end

    test "tags ignore markdown headings" do
      assert Notes.parse_tags("# Heading\nbody #real and ## H2") == ["real"]
    end
  end

  describe "update_note/3 with partial attrs" do
    test "keeps fields that are absent from attrs", %{user: user} do
      {:ok, note} =
        Notes.create_note(user.id, %{
          "title" => "Keep",
          "folder" => "Stuff",
          "body" => "content #tag"
        })

      {:ok, updated} = Notes.update_note(user.id, note.id, %{"title" => "Kept"})

      assert updated.title == "Kept"
      assert updated.data["body"] == "content #tag"
      assert updated.data["folder"] == "Stuff"
      assert updated.data["tags"] == ["tag"]
      assert updated.external_id == "stuff/kept"
    end
  end

  describe "user scoping" do
    test "list/get/backlinks never cross users", %{user: user, other: other} do
      {:ok, mine} = Notes.create_note(user.id, %{"title" => "Mine", "body" => "[[Mine]]"})
      {:ok, _theirs} = Notes.create_note(other.id, %{"title" => "Theirs", "body" => ""})

      assert Enum.map(Notes.list_notes(user.id), & &1.id) == [mine.id]
      assert_raise Ecto.NoResultsError, fn -> Notes.get_note!(other.id, mine.id) end
      assert Notes.backlinks(other.id, mine) == []
    end
  end

  describe "delete_note/2" do
    test "removes the note and its outgoing links", %{user: user} do
      {:ok, target} = Notes.create_note(user.id, %{"title" => "T", "body" => ""})
      {:ok, source} = Notes.create_note(user.id, %{"title" => "S", "body" => "[[T]]"})

      {:ok, _} = Notes.delete_note(user.id, source.id)

      assert Notes.list_notes(user.id) |> Enum.map(& &1.id) == [target.id]
      assert Notes.backlinks(user.id, target) == []
    end
  end
end
