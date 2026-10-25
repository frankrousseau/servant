defmodule Servant.Repo.Migrations.AddTraceToSyncLogs do
  use Ecto.Migration

  # What a sync run did, beside its status: the entries the connector
  # returned (entries_count stays the new ones), how many HTTP calls and log
  # lines it made, and their detail (kept on the most recent runs only).
  def up do
    alter table(:sync_logs) do
      add :fetched_count, :integer, null: false, default: 0
      add :http_count, :integer, null: false, default: 0
      add :http_failed_count, :integer, null: false, default: 0
      add :log_count, :integer, null: false, default: 0
      add :details, :map
    end

    # Older runs only counted what they inserted: that is all they fetched,
    # as far as anyone knows.
    execute "UPDATE sync_logs SET fetched_count = entries_count"
  end

  def down do
    alter table(:sync_logs) do
      remove :fetched_count
      remove :http_count
      remove :http_failed_count
      remove :log_count
      remove :details
    end
  end
end
