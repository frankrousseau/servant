defmodule Servant.Repo.Migrations.MigrateToUuids do
  use Ecto.Migration

  @doc """
  Migrates all tables from integer PKs to UUID (TEXT) PKs.
  SQLite doesn't support ALTER COLUMN, so we rename → recreate → copy → drop.
  """

  def change do
    # We use execute for raw SQL since this migration is SQLite-specific
    # and involves complex data copying with UUID generation.

    # ============================================================
    # 1. USERS — no foreign key dependencies for its PK
    # ============================================================
    execute """
            CREATE TABLE users_new (
              id TEXT PRIMARY KEY NOT NULL,
              username TEXT NOT NULL,
              hashed_password TEXT,
              display_name TEXT,
              email TEXT,
              avatar_path TEXT,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS users_new"

    execute """
            INSERT INTO users_new (id, username, hashed_password, display_name, email, avatar_path, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              username, hashed_password, display_name, email, avatar_path, inserted_at, updated_at
            FROM users
            """,
            ""

    # Create temp mapping table for FK resolution
    execute """
            CREATE TABLE _user_id_map (old_id INTEGER NOT NULL, new_id TEXT NOT NULL)
            """,
            "DROP TABLE IF EXISTS _user_id_map"

    execute """
            INSERT INTO _user_id_map (old_id, new_id)
            SELECT u_old.id, u_new.id
            FROM users u_old
            JOIN users_new u_new ON u_old.username = u_new.username
            """,
            ""

    # ============================================================
    # 2. ENTRIES
    # ============================================================
    execute """
            CREATE TABLE entries_new (
              id TEXT PRIMARY KEY NOT NULL,
              user_id TEXT NOT NULL REFERENCES users_new(id) ON DELETE CASCADE,
              kind TEXT,
              source TEXT,
              external_id TEXT,
              title TEXT,
              occurred_at TEXT,
              data TEXT DEFAULT '{}',
              metadata TEXT DEFAULT '{}',
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS entries_new"

    execute """
            INSERT INTO entries_new (id, user_id, kind, source, external_id, title, occurred_at, data, metadata, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              m.new_id, e.kind, e.source, e.external_id, e.title, e.occurred_at, e.data, e.metadata, e.inserted_at, e.updated_at
            FROM entries e
            JOIN _user_id_map m ON e.user_id = m.old_id
            """,
            ""

    # ============================================================
    # 3. CREDENTIALS
    # ============================================================
    execute """
            CREATE TABLE credentials_new (
              id TEXT PRIMARY KEY NOT NULL,
              user_id TEXT NOT NULL REFERENCES users_new(id) ON DELETE CASCADE,
              connector_type TEXT NOT NULL,
              data BLOB,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS credentials_new"

    execute """
            INSERT INTO credentials_new (id, user_id, connector_type, data, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              m.new_id, c.connector_type, c.data, c.inserted_at, c.updated_at
            FROM credentials c
            JOIN _user_id_map m ON c.user_id = m.old_id
            """,
            ""

    # ============================================================
    # 4. CONNECTOR_CONFIGS
    # ============================================================
    execute """
            CREATE TABLE connector_configs_new (
              id TEXT PRIMARY KEY NOT NULL,
              user_id TEXT NOT NULL REFERENCES users_new(id) ON DELETE CASCADE,
              connector_type TEXT NOT NULL,
              name TEXT,
              enabled INTEGER DEFAULT 0,
              config TEXT DEFAULT '{}',
              schedule TEXT DEFAULT 'every_hour' NOT NULL,
              last_synced_at TEXT,
              error TEXT,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS connector_configs_new"

    execute """
            INSERT INTO connector_configs_new (id, user_id, connector_type, name, enabled, config, schedule, last_synced_at, error, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              m.new_id, cc.connector_type, cc.name, cc.enabled, cc.config, cc.schedule, cc.last_synced_at, cc.error, cc.inserted_at, cc.updated_at
            FROM connector_configs cc
            JOIN _user_id_map m ON cc.user_id = m.old_id
            """,
            ""

    # Create connector_config mapping for sync_logs FK
    execute """
            CREATE TABLE _cc_id_map (old_id INTEGER NOT NULL, new_id TEXT NOT NULL)
            """,
            "DROP TABLE IF EXISTS _cc_id_map"

    execute """
            INSERT INTO _cc_id_map (old_id, new_id)
            SELECT cc_old.id, cc_new.id
            FROM connector_configs cc_old
            JOIN _user_id_map um ON cc_old.user_id = um.old_id
            JOIN connector_configs_new cc_new ON cc_new.user_id = um.new_id
              AND cc_new.connector_type = cc_old.connector_type
              AND cc_new.inserted_at = cc_old.inserted_at
            """,
            ""

    # ============================================================
    # 5. SYNC_LOGS
    # ============================================================
    execute """
            CREATE TABLE sync_logs_new (
              id TEXT PRIMARY KEY NOT NULL,
              connector_config_id TEXT NOT NULL REFERENCES connector_configs_new(id) ON DELETE CASCADE,
              status TEXT NOT NULL,
              entries_count INTEGER DEFAULT 0,
              error TEXT,
              started_at TEXT NOT NULL,
              finished_at TEXT,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS sync_logs_new"

    execute """
            INSERT INTO sync_logs_new (id, connector_config_id, status, entries_count, error, started_at, finished_at, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              cm.new_id, sl.status, sl.entries_count, sl.error, sl.started_at, sl.finished_at, sl.inserted_at, sl.updated_at
            FROM sync_logs sl
            JOIN _cc_id_map cm ON sl.connector_config_id = cm.old_id
            """,
            ""

    # ============================================================
    # 6. SETTINGS
    # ============================================================
    execute """
            CREATE TABLE settings_new (
              id TEXT PRIMARY KEY NOT NULL,
              user_id TEXT REFERENCES users_new(id) ON DELETE CASCADE,
              key TEXT,
              value TEXT,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS settings_new"

    execute """
            INSERT INTO settings_new (id, user_id, key, value, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              m.new_id, s.key, s.value, s.inserted_at, s.updated_at
            FROM settings s
            LEFT JOIN _user_id_map m ON s.user_id = m.old_id
            """,
            ""

    # ============================================================
    # 7. CONNECTOR_ENVIRONMENT (no FK, standalone)
    # ============================================================
    execute """
            CREATE TABLE connector_environment_new (
              id TEXT PRIMARY KEY NOT NULL,
              connector_type TEXT NOT NULL,
              namespace TEXT NOT NULL,
              key TEXT NOT NULL,
              value TEXT DEFAULT '{}' NOT NULL,
              expires_at TEXT,
              inserted_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """,
            "DROP TABLE IF EXISTS connector_environment_new"

    execute """
            INSERT INTO connector_environment_new (id, connector_type, namespace, key, value, expires_at, inserted_at, updated_at)
            SELECT
              lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab', abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
              connector_type, namespace, key, value, expires_at, inserted_at, updated_at
            FROM connector_environment
            """,
            ""

    # ============================================================
    # 8. SWAP: drop old tables, rename new tables
    # ============================================================
    # Must drop in reverse dependency order
    execute "DROP TABLE IF EXISTS sync_logs", ""
    execute "DROP TABLE IF EXISTS settings", ""
    execute "DROP TABLE IF EXISTS credentials", ""
    execute "DROP TABLE IF EXISTS entries", ""
    execute "DROP TABLE IF EXISTS connector_configs", ""
    execute "DROP TABLE IF EXISTS connector_environment", ""
    execute "DROP TABLE IF EXISTS users", ""

    execute "ALTER TABLE users_new RENAME TO users", ""
    execute "ALTER TABLE entries_new RENAME TO entries", ""
    execute "ALTER TABLE credentials_new RENAME TO credentials", ""
    execute "ALTER TABLE connector_configs_new RENAME TO connector_configs", ""
    execute "ALTER TABLE sync_logs_new RENAME TO sync_logs", ""
    execute "ALTER TABLE settings_new RENAME TO settings", ""
    execute "ALTER TABLE connector_environment_new RENAME TO connector_environment", ""

    # Cleanup mapping tables
    execute "DROP TABLE IF EXISTS _cc_id_map", ""
    execute "DROP TABLE IF EXISTS _user_id_map", ""

    # ============================================================
    # 9. Recreate indexes
    # ============================================================
    create unique_index(:users, [:username])
    create index(:entries, [:user_id, :kind])
    create index(:entries, [:user_id, :source])
    create index(:entries, [:user_id, :occurred_at])
    create unique_index(:entries, [:user_id, :source, :external_id])
    create index(:sync_logs, [:connector_config_id])
    create index(:sync_logs, [:started_at])
    create unique_index(:connector_environment, [:connector_type, :namespace, :key])
    create index(:connector_environment, [:expires_at])
  end
end
