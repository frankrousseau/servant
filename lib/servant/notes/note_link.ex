defmodule Servant.Notes.NoteLink do
  @moduledoc """
  A directed link from one note to a target entry, maintained by
  `Servant.Notes` on every note save. Two kinds:

    * `"wikilink"`: a `[[link]]` to another note (by title or folder/title
      path); powers backlinks and, later, the note graph.
    * `"mention"`: a `@[[mention]]` of a contact or event entry.

  `target_note_id` is resolved when the target entry exists (a note for
  wikilinks, a contact/event for mentions).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "note_links" do
    field :target_path, :string
    field :kind, :string, default: "wikilink"

    belongs_to :user, Servant.Accounts.User
    belongs_to :source_note, Servant.Data.Entry
    belongs_to :target_note, Servant.Data.Entry

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(note_link, attrs) do
    note_link
    |> cast(attrs, [:target_path, :target_note_id, :kind])
    |> validate_required([:target_path])
    |> validate_inclusion(:kind, ["wikilink", "mention"])
  end
end
