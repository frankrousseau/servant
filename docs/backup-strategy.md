# Backup Strategy

This page tells you how to back up and restore a Servant instance. If you lose the machine,
these backups let you get all the data back. For deployment, see [deploy.md](deploy.md).

## What to back up

Back up these three items. If one is missing, the restore is not complete.

| What | Where | Why |
|------|-------|-----|
| The SQLite database | `DATABASE_PATH` (`/data/servant.db` in Docker) | Entries, notes, accounts, connector configs, agents, API tokens. |
| The files directory | `FILES_DIR` (`/data/files` in Docker) | Uploaded files, photos, avatars, connector import archives. The database keeps only the paths. |
| The secrets | `.env` or systemd unit: `SECRET_KEY_BASE`, `CONNECTOR_ENCRYPTION_KEY` (if set) | The connector secrets are encrypted with a key from these values. With a different key, Servant cannot decrypt the connector credentials, and you must enter them all again. |

You do not need to back up `TMP_DIR` (temporary files), the Docker image, the release build or
`priv/static`. You can build them again from the repo.

> **WARNING:** Keep the secrets **separately from the backups** (for example, in a password
> manager). A person with the database and `SECRET_KEY_BASE` can decrypt your connector
> credentials and make session tokens.

## Back up the database

SQLite uses WAL mode. While Servant runs, some recent writes are in `servant.db-wal`, next to
the main file.

> **CAUTION:** Do not copy `servant.db` alone while Servant runs. The copy can be old or
> corrupt.

Use one of these two procedures.

**Option A (recommended): SQLite online backup.** Servant can continue to run. The result is
one consistent file:

```bash
sqlite3 /data/servant.db ".backup /backups/servant-$(date +%F).db"
```

`VACUUM INTO` gives the same result and also makes the copy smaller:

```bash
sqlite3 /data/servant.db "VACUUM INTO '/backups/servant-$(date +%F).db'"
```

**Option B: cold copy.** Stop Servant. Copy the file, and the `-wal` and `-shm` files if they
exist. Start Servant. This is always correct, but Servant is unavailable for a short time.

## Back up the files

`FILES_DIR` contains plain files. Servant writes uploads and photos one time and almost never
changes them. You can use any file tool while Servant runs:

```bash
rsync -a /data/files/ /backups/files/
```

For offsite copies, use an incremental, encrypted tool, for example
[restic](https://restic.net/) or [borg](https://www.borgbackup.org/). Photos make this
directory the largest part of the backup, and these tools deduplicate it well.

## Recipes

### Docker

The compose setup keeps all the data in one volume (`/data`). Run this script on the host each
night:

```bash
#!/bin/sh
set -eu
BACKUP_DIR=/backups/servant
mkdir -p "$BACKUP_DIR"

# 1. Consistent database snapshot (the image must contain sqlite3)
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

If the image does not contain `sqlite3`, make a cold copy: `docker compose stop servant`,
copy the volume, `docker compose start servant`.

Then copy `$BACKUP_DIR` to a different machine with restic, borg or `rsync`.

### Bare metal

This script uses the `/var/lib/servant/` layout of the deploy guide:

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

Run it with cron or a systemd timer:

```
0 3 * * * /usr/local/bin/servant-backup.sh
```

## The 3-2-1 rule

One copy on the same disk is not sufficient. Keep:

- **3** copies of the data (the live data is one copy),
- on **2** different media or machines,
- with **1** copy offsite (a different site, a NAS at a friend's home, encrypted cloud storage).

restic or borg with a remote repository gives the last two items, with end-to-end encryption.

## Restore

1. Install Servant ([deploy.md](deploy.md)). Do not register an account.
2. Set `SECRET_KEY_BASE` (and `CONNECTOR_ENCRYPTION_KEY` if you used it) to the **original**
   values.
3. Stop Servant.
4. Copy the database snapshot to `DATABASE_PATH`.
5. Copy the files backup to `FILES_DIR`.
6. Remove the `-wal` and `-shm` files next to the restored database, if they exist.
7. Start Servant. With Docker, the migrations run at start. On bare metal, run
   `bin/servant eval "Servant.Release.migrate"`. The migrations also upgrade a snapshot from an
   older version.
8. Log in and do these checks:
   - The recent entries are there.
   - A photo opens (the files are restored).
   - A connector syncs (the encryption key is correct).

**Test the restore before you need it.** One or two times each year, restore into a temporary
container and do the checks of step 8.

## Other copies (not a backup)

These copies help, but they do not replace the instance backup:

- **JSON export**: `GET /api/export/entries` (or Settings) downloads all your entries as one
  JSON file. It is per user and has no files or photos. There is no import function.
- **iCal export**: `GET /api/export/ical` for the calendar entries.
- **CalDAV / CardDAV sync** ([dav.md](dav.md)): a phone that syncs contacts and calendars keeps
  one more copy of these two data sets.

## Summary

| | |
|---|---|
| Back up | `DATABASE_PATH` (with `sqlite3 .backup`) + `FILES_DIR` + secrets |
| Frequency | Each night, automatic (cron or systemd timer) |
| Offsite | restic or borg to a remote repository |
| Restore test | One or two times each year, into a temporary instance |
