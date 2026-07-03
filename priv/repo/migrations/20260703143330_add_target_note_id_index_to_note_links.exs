defmodule Servant.Repo.Migrations.AddTargetNoteIdIndexToNoteLinks do
  use Ecto.Migration

  def change do
    # `Notes.reconcile_inbound/2` and `inbound_source_ids/1` filter note_links by
    # target_note_id on every note save; without this index those were table scans.
    create index(:note_links, [:target_note_id])
  end
end
