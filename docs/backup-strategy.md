# Backup Strategy

How to back up a Servant instance so you can lose the machine and still get everything back.
Deployment itself is covered in [deploy.md](deploy.md); this page only deals with saving and
restoring your data.

## What to back up

A Servant instance is exactly three things. Lose any of them and the restore is incomplete.

| What | Where | Why |
|------|-------|-----|
| The SQLite database | `DATABASE_PATH` (`/data/servant.db` in Docker) | All entries, notes, accounts, connector configs, agents, API tokens. |
| The files directory | `FILES_DIR` (`/data/files` in Docker) | Uploaded files, photos, avatars, connector import archives. The database only stores paths, not file contents. |
| Your secrets | `.env` / systemd unit: `SECRET_KEY_BASE`, `CONNECTOR_ENCRYPTION_KEY` (if set) | Connector secrets are encrypted at rest with a key derived from these. Restore the database with a different key and every connector credential becomes undecryptable; you would have to re-enter them all. |

Not needed: `TMP_DIR` (scratch space, safe to lose), the Docker image or release build
(rebuildable from the repo), `priv/static` (baked into the image).

> Store the secrets **separately from the backups** (a password manager is fine). Anyone holding
> both the database and `SECRET_KEY_BASE` can decrypt your connector credentials and forge
> session tokens.

## Backing up the database

SQLite runs in WAL mode, so while Servant is running, part of the latest writes lives in
`servant.db-wal` next to the main file. **Never copy `servant.db` alone while the app is
running**: you can get a stale or corrupt snapshot. Two safe options:

**Option A (recommended): SQLite online backup.** Works while Servant is running, produces a
single consistent file:

```bash
sqlite3 /data/servant.db ".backup /backups/servant-$(date +%F).db"
```

`VACUUM INTO` is an equivalent alternative and also compacts the copy:

```bash
sqlite3 /data/servant.db "VACUUM INTO '/backups/servant-$(date +%F).db'"
```

**Option B: cold copy.** Stop Servant, copy the file (plus `-wal` and `-shm` if present), start
it again. Simple and always correct, at the cost of a short downtime.

## Backing up the files

`FILES_DIR` is plain files, append-mostly (uploads and photos are written once, rarely
modified). Any file-level tool works, run it while Servant is up:

```bash
rsync -a /data/files/ /backups/files/
```

For offsite copies, prefer an incremental, encrypted tool such as
[restic](https://restic.net/) or [borg](https://www.borgbackup.org/); photos make this
directory the biggest part of the backup by far, and both deduplicate it well.

## Recipes

### Docker

The compose setup keeps everything under one volume (`/data`). A nightly backup script on the
host:

```bash
#!/bin/sh
set -eu
BACKUP_DIR=/backups/servant
mkdir -p "$BACKUP_DIR"

# 1. Consistent database snapshot (sqlite3 must be installed on the host)
docker compose exec -T servant sh -c \
  "sqlite3 /data/servant.db \".backup /data/servant-snapshot.db\""
docker cp "$(docker compose ps -q servant)":/data/servant-snapshot.db \
  "$BACKUP_DIR/servant-$(date +%F).db"
docker compose exec -T servant rm /data/servant-snapshot.db

# 2. Files
docker cp "$(docker compose ps -q servant)":/data/files "$BACKUP_DIR/files"

# 3. Keep the last 14 database snapshots
ls -1t "$BACKUP_DIR"/servant-*.db | tail -n +15 | xargs -r rm
```

If the `sqlite3` CLI is not in the image, fall back to a cold copy:
`docker compose stop servant`, copy the volume, `docker compose start servant`.

Then point restic/borg (or a simple `rsync` to another machine) at `$BACKUP_DIR`.

### Bare metal

With data under `/var/lib/servant/` as in the deploy guide:

```bash
#!/bin/sh
set -eu
BACKUP_DIR=/backups/servant
mkdir -p "$BACKUP_DIR"

sqlite3 /var/lib/servant/servant.db \
  ".backup $BACKUP_DIR/servant-$(date +%F).db"
rsync -a /var/lib/servant/files/ "$BACKUP_DIR/files/"
ls -1t "$BACKUP_DIR"/servant-*.db | tail -n +15 | xargs -r rm
```

Schedule it with cron or a systemd timer:

```
0 3 * * * /usr/local/bin/servant-backup.sh
```

## The 3-2-1 rule

One nightly copy on the same disk is not a backup strategy. Aim for:

- **3** copies of the data (the live one counts as one),
- on **2** different media or machines,
- **1** of them offsite (another site, a friend's NAS, encrypted cloud storage).

restic or borg against a remote repository covers the last two points in one tool, encrypted
end to end.

## Restoring

1. Install Servant as usual ([deploy.md](deploy.md)), but do not register an account.
2. Set `SECRET_KEY_BASE` (and `CONNECTOR_ENCRYPTION_KEY` if you had one) to the **original**
   values from your secrets backup.
3. Stop Servant. Copy the database snapshot to `DATABASE_PATH` and the files backup to
   `FILES_DIR`. Remove any leftover `-wal` / `-shm` files next to the restored database.
4. Start Servant. Migrations run on start (Docker) or via
   `bin/servant eval "Servant.Release.migrate"` (bare metal), which also upgrades a snapshot
   taken on an older version.
5. Log in with your usual credentials and check a few things: recent entries are there, a photo
   opens (files restore), a connector syncs (encryption key is right).

**Test this before you need it.** A backup that has never been restored is a hope, not a
backup. Once or twice a year, restore into a throwaway container and run the checks in step 5.

## Lighter safety nets (not substitutes)

These exist and help, but none of them replaces the instance backup above:

- **JSON export**: `GET /api/export/entries` (or Settings) downloads all your entries as one
  JSON file. Per user, no files/photos, and there is no importer today; it is an
  escape-hatch copy of your data, not a restore path.
- **iCal export**: `GET /api/export/ical` for calendar entries.
- **CalDAV / CardDAV sync** ([dav.md](dav.md)): a phone syncing contacts and calendars keeps an
  extra live copy of those two datasets.

## Summary

| | |
|---|---|
| Back up | `DATABASE_PATH` (via `sqlite3 .backup`) + `FILES_DIR` + secrets |
| Frequency | Nightly, automated (cron / systemd timer) |
| Offsite | restic or borg to a remote repository |
| Restore test | Once or twice a year, into a throwaway instance |
