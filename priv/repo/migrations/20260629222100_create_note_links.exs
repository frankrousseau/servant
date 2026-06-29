defmodule Servant.Repo.Migrations.CreateNoteLinks do
  use Ecto.Migration

  def change do
    create table(:note_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :source_note_id, references(:entries, type: :binary_id, on_delete: :delete_all),
        null: false

      add :target_path, :string, null: false
      add :target_note_id, references(:entries, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Backlinks: "which notes link to this path/slug?"
    create index(:note_links, [:user_id, :target_path])
    # Re-indexing a note's outgoing links on save.
    create index(:note_links, [:source_note_id])
  end
end
