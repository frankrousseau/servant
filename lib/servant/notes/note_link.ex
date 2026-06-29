defmodule Servant.Notes.NoteLink do
  @moduledoc """
  A directed `[[wikilink]]` from one note to a target path/slug. Maintained by
  `Servant.Notes` on every note save and used to compute backlinks (and, later,
  the note graph). `target_note_id` is resolved when the target note exists.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "note_links" do
    field :target_path, :string

    belongs_to :user, Servant.Accounts.User
    belongs_to :source_note, Servant.Data.Entry
    belongs_to :target_note, Servant.Data.Entry

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(note_link, attrs) do
    note_link
    |> cast(attrs, [:target_path, :target_note_id])
    |> validate_required([:target_path])
  end
end
