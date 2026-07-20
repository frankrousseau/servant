defmodule Servant.Repo.Migrations.MakePromptNullable do
  @moduledoc """
  Widens `agents.prompt` to allow nil (recipe-mode agents don't need a
  prompt, only prompt-mode agents do). exqlite/ecto_sqlite3 does not
  support `ALTER COLUMN`, so this recreates the table (SQLite's standard
  12-step ALTER TABLE procedure) instead of using `modify`.

  Two things make this table special compared to the `user_apps` rebuild
  this migration is otherwise modeled on:

    * `agent_runs.agent_id` holds a foreign key into `agents` with
      `on_delete: :nilify_all`. Ecto migrations run inside a transaction,
      and SQLite's `PRAGMA foreign_keys` is a no-op while a transaction is
      open, so toggling it inside `up`/`down` would silently do nothing:
      `DROP TABLE agents` would still perform its implicit
      `DELETE FROM agents`, and the FK's `ON DELETE` action would fire and
      null out every `agent_runs.agent_id`. `@disable_ddl_transaction`
      keeps this migration outside a transaction so the pragma actually
      takes effect around the rebuild.
    * With `PRAGMA foreign_keys` enabled, renaming the *old* `agents`
      table aside (the `user_apps` migration's pattern) makes SQLite
      rewrite `agent_runs`'s `REFERENCES agents(id)` clause to point at
      the renamed-away table, so dropping it afterwards still fires the
      FK action and, worse, permanently leaves `agent_runs` referencing a
      table name that no longer exists. To avoid both problems, the
      replacement table is built under a temporary name and the
      original `agents` is dropped outright (never renamed) before the
      replacement is renamed into place, so `agent_runs`'s
      `REFERENCES agents(id)` clause is never rewritten and always
      resolves to whichever table is currently named `agents`.
    * `PRAGMA foreign_keys` is per-connection, and the SQLite adapter's
      `lock_for_migrations/3` is a no-op (SQLite has no advisory locks),
      so nothing normally pins this migration to a single pooled
      connection once `@disable_ddl_transaction` removes Ecto's own
      transaction-based checkout. With a pool bigger than one connection,
      later statements in this migration could land on a different,
      still-`foreign_keys = ON` connection than the one the pragma was
      turned off on (and, separately, `rename` can fail with "already
      another table ... with this name" if `drop table(:agents)` runs on
      a different connection than the one that runs the rename). Wrapping
      the whole rebuild in `repo().checkout/1` pins one connection for
      every statement below, the same way Ecto's own DDL transaction
      would if we could use one. `Ecto.Migration`'s DSL only *queues*
      commands; they are normally flushed after `up/0`/`down/0` returns,
      which is *outside* the `checkout/1` block and would defeat the
      pinning. The explicit `flush()` at the end of each block forces
      every queued command to run while the connection is still pinned.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  @columns "id, user_id, name, prompt, mode, recipe, kinds, lookback_days, schedule, enabled, last_run_at, inserted_at, updated_at"

  def up do
    repo().checkout(fn ->
      execute("PRAGMA foreign_keys = OFF")

      create table(:agents_new, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
        add :name, :string, null: false
        add :prompt, :text
        add :mode, :string, null: false, default: "prompt"
        add :recipe, :map
        add :kinds, {:array, :string}, null: false
        add :lookback_days, :integer, null: false, default: 7
        add :schedule, :string, null: false, default: "every_day"
        add :enabled, :boolean, null: false, default: true
        add :last_run_at, :utc_datetime

        timestamps(type: :utc_datetime)
      end

      execute "INSERT INTO agents_new (#{@columns}) SELECT #{@columns} FROM agents"

      drop table(:agents)
      rename table(:agents_new), to: table(:agents)

      create index(:agents, [:user_id])

      execute("PRAGMA foreign_keys = ON")
      flush()
    end)
  end

  def down do
    repo().checkout(fn ->
      execute("PRAGMA foreign_keys = OFF")

      create table(:agents_new, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
        add :name, :string, null: false
        add :prompt, :text, null: false
        add :mode, :string, null: false, default: "prompt"
        add :recipe, :map
        add :kinds, {:array, :string}, null: false
        add :lookback_days, :integer, null: false, default: 7
        add :schedule, :string, null: false, default: "every_day"
        add :enabled, :boolean, null: false, default: true
        add :last_run_at, :utc_datetime

        timestamps(type: :utc_datetime)
      end

      execute "INSERT INTO agents_new (#{@columns}) SELECT #{@columns} FROM agents"

      drop table(:agents)
      rename table(:agents_new), to: table(:agents)

      create index(:agents, [:user_id])

      execute("PRAGMA foreign_keys = ON")
      flush()
    end)
  end
end
