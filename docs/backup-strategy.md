# Backups

**Save three things every night, keep a copy offsite, test a restore once a year.**

## What to save

| | Where | Why |
|---|---|---|
| **Database** | `DATABASE_PATH` (`/data/servant.db` in Docker) | Entries, notes, accounts, sources, agents, API tokens. |
| **Files** | `FILES_DIR` (`/data/files` in Docker) | Uploads, photos, avatars, imports. The database only holds their paths. |
| **Secrets** | `SECRET_KEY_BASE`, and `CONNECTOR_ENCRYPTION_KEY` if set (`.env` or systemd unit) | They decrypt your source credentials. Without them, you enter every credential again. |

Skip `TMP_DIR` (temporary files) and what the repo rebuilds: the Docker image, the release,
`priv/static`.

> [!WARNING]
> **Store the secrets apart from the backups**, in a password manager for example: the
> database plus `SECRET_KEY_BASE` lets anyone decrypt your credentials and forge sessions.

## Database

> [!CAUTION]
> Never copy `servant.db` alone while Servant runs: the recent writes sit in `servant.db-wal`
> (SQLite WAL mode), so the copy can be stale or corrupt.

**Online backup** (recommended): Servant keeps running, and you get one consistent file.

```bash
sqlite3 /data/servant.db ".backup /backups/servant-$(date +%F).db"
sqlite3 /data/servant.db "VACUUM INTO '/backups/servant-$(date +%F).db'"   # same, smaller
```

**Cold copy:** stop Servant, copy the file with its `-wal` and `-shm` files if any, start
Servant.

## Files

Plain files, written once and almost never changed: copy them any time.

```bash
rsync -a /data/files/ /backups/files/
```

Photos make this the heaviest part. Offsite, [restic](https://restic.net/) or
[borg](https://www.borgbackup.org/) deduplicate and encrypt it.

## Nightly scripts

### Docker

Run this on the host every night:

```bash
#!/bin/sh
set -eu
BACKUP_DIR=/backups/servant
mkdir -p "$BACKUP_DIR"

# 1. Consistent database snapshot (needs sqlite3 in the image, see below)
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

> [!NOTE]
> The stock image has no `sqlite3`. Add it to the `apt-get install` line of the runtime stage
> in the `Dockerfile`, or make a cold copy instead (`docker compose stop servant`, copy the
> volume, `docker compose start servant`).

Then ship `$BACKUP_DIR` to another machine with restic, borg or `rsync`.

### Bare metal

With the `/var/lib/servant/` layout of the [deployment guide](deploy.md#bare-metal-release):

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

Schedule it with cron (or a systemd timer):

```
0 3 * * * /usr/local/bin/servant-backup.sh
```

## The 3-2-1 rule

**3** copies (the live data counts) on **2** different machines or media, **1** of them
offsite: a friend's NAS, encrypted cloud storage. restic or borg with a remote repository
covers the last two.

## Restore

1. Install Servant ([Deployment](deploy.md)), without registering an account.
2. Set `SECRET_KEY_BASE` (and `CONNECTOR_ENCRYPTION_KEY` if you set one) to the **original**
   values.
3. Stop Servant.
4. Copy the snapshot to `DATABASE_PATH` and the files to `FILES_DIR`. Delete any `-wal` and
   `-shm` file next to the database.
5. Start Servant. Docker migrates at start; on bare metal, run
   `bin/servant eval "Servant.Release.migrate"` (older snapshots upgrade too).
6. Log in and check:
   - [ ] the recent entries are there;
   - [ ] a photo opens (the files are back);
   - [ ] a source syncs (the key is right).

> [!TIP]
> **Test the restore before you need it:** once or twice a year, into a throwaway container.

## Extra copies, not backups

- **JSON export** (**Settings > Export**, or `GET /api/export/entries`): your entries, without
  the files, and there is no import.
- **iCal export** (`GET /api/export/ical`): your calendar entries.
- **Phone sync** ([dav.md](dav.md)): your phone holds a copy of your contacts and calendars.
