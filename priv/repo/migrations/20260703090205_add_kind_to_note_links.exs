defmodule Servant.Repo.Migrations.AddKindToNoteLinks do
  use Ecto.Migration

  def change do
    alter table(:note_links) do
      # "wikilink" — [[link]] to another note; "mention" — @[[mention]] of a
      # contact or event entry.
      add :kind, :string, null: false, default: "wikilink"
    end
  end
end
