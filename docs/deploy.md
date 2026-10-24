# Deployment

**One release, one SQLite file, one port. Servant runs happily on a Raspberry Pi.**

| | [Docker](#docker-recommended) (recommended) | [Bare metal](#bare-metal-release) |
|---|---|---|
| **You run** | `docker compose up` | a `mix release`, under systemd |
| **Migrations** | at each start | by hand, after each upgrade |

> [!WARNING]
> **Protect your data first.** `DATABASE_PATH` and `FILES_DIR` must point outside the release
> directory (a Docker volume, `/var/lib/servant/`), or each redeploy wipes your database and
> files. The Docker image takes care of it.

## Docker (recommended)

```bash
# 1. A secret and the public hostname, in .env (compose reads it)
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> .env
echo "PHX_HOST=servant.local" >> .env

# 2. Build and start
docker compose up -d --build

# 3. Follow the logs
docker compose logs -f servant
```

Open `http://localhost:4000`, register the first account, add your sources. The image keeps
everything on the `/data` volume and migrates at each start: you only set `SECRET_KEY_BASE`
and `PHX_HOST`.

### Without compose

Keep the settings in a file, so that the secret survives a new container:

```bash
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> servant.env
echo "PHX_HOST=servant.local" >> servant.env

docker build -t servant:latest .
docker volume create servant_data
docker run -d --name servant \
  -p 4000:4000 \
  --env-file servant.env \
  -v servant_data:/data \
  --restart unless-stopped \
  servant:latest
```

## Bare metal (release)

### Prerequisites

- Erlang 29+ and Elixir 1.20+ (pinned in `.tool-versions`).
- Node.js 22+ to build the frontend, and at runtime for the **Invoice Collector** source
  (run `npm install` in `priv/scrapers/`).
- `libvips` at runtime, for the photo thumbnails (`vix`). With `libheif`, it also previews
  HEIC photos; most distribution packages have it.

### Build

```bash
mix deps.get --only prod
cd frontend && npm ci && npm run build && cd ..   # vite writes into priv/static/
MIX_ENV=prod mix compile
MIX_ENV=prod mix phx.digest
MIX_ENV=prod mix release                          # into _build/prod/rel/servant/
```

### Run

Generate the secret once (`mix phx.gen.secret`) and keep it: a new secret logs everyone out and
makes the stored source credentials unreadable.

```bash
SECRET_KEY_BASE=<your-secret> \
DATABASE_PATH=/var/lib/servant/servant.db \
FILES_DIR=/var/lib/servant/files \
PHX_HOST=servant.local \
PHX_SERVER=true \
_build/prod/rel/servant/bin/servant start
```

Migrations do not run by themselves. After each upgrade:

```bash
_build/prod/rel/servant/bin/servant eval "Servant.Release.migrate"
```

### systemd

Create `/etc/systemd/system/servant.service`:

```ini
[Unit]
Description=Servant
After=network.target

[Service]
Type=exec
User=servant
Group=servant
WorkingDirectory=/opt/servant
ExecStart=/opt/servant/bin/servant start
ExecStop=/opt/servant/bin/servant stop
Restart=on-failure
RestartSec=5

Environment=PHX_SERVER=true
Environment=PORT=4000
Environment=PHX_HOST=servant.local
Environment=DATABASE_PATH=/var/lib/servant/servant.db
Environment=FILES_DIR=/var/lib/servant/files
Environment=TMP_DIR=/var/lib/servant/tmp
Environment=SECRET_KEY_BASE=<your-secret>

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now servant
```

## Environment variables

| Variable | Required | Default | What it does |
|----------|:--------:|---------|--------------|
| `SECRET_KEY_BASE` | ✅ | | Signs tokens and cookies (`mix phx.gen.secret` or `openssl rand -base64 48`). |
| `PHX_HOST` | ✅ | `example.com` | Public hostname, for URLs and the socket origin check. |
| `PHX_SERVER` | ✅ | `true` in the Docker image | Starts the HTTP server. |
| `DATABASE_PATH` | ✅ | `/data/servant.db` in the Docker image | Absolute path to the SQLite file, on persistent storage. |
| `FILES_DIR` | ✅ in practice | `/data/files` in the Docker image, else `priv/files` | Uploads, photos and source archives. **The default lives in the release directory, and each redeploy deletes it.** |
| `TMP_DIR` | | `/data/tmp` in the Docker image, else `priv/tmp` | Scratch space for source imports. You can empty it. |
| `PORT` | | `4000` | HTTP port. |
| `POOL_SIZE` | | `5` | SQLite connections. |
| `REGISTRATION_ENABLED` | | `true` | `false` closes registration; existing users still log in. |
| `AGENT_CONCURRENCY` | | `1` | Agents that can run at once. `1` for a self-hosted model server, more for a hosted API. |
| `CONNECTOR_ENCRYPTION_KEY` | | derived from `SECRET_KEY_BASE` | Encrypts the source secrets at rest (AES-256-GCM). Set it to manage this key separately from `SECRET_KEY_BASE`. **When this key changes (or `SECRET_KEY_BASE`, if this key is not set), you enter the secrets again.** |
| `UPLOADS_DIR` | | `priv/uploads` | Legacy uploads, read only, for files older than `FILES_DIR`. |

## Day to day

```bash
# Update: rebuild, restart, run the new migrations
git pull && docker compose up -d --build

# Run the migrations by hand (each start already does)
docker compose exec servant bin/servant eval "Servant.Release.migrate"

# Remote IEx console on the running release
docker compose exec servant bin/servant remote
```

**Back up** the database with `sqlite3 .backup`, never a plain copy, and `FILES_DIR` with it:
see [Backups](backup-strategy.md).

### One-time backfills

Older versions missed some data. Each backfill repairs it once; run the ones that match your
history:

```bash
docker compose exec servant bin/servant eval "Servant.Release.<backfill>"
```

| `<backfill>` | Run it if |
|--------------|-----------|
| `backfill_photo_exif` | You imported iPhone HEIC photos before HEIC EXIF support: they lack date and location. Stored values stay as they are. |
| `backfill_carddav_contacts` | Your iPhone contacts synced before October 2026: some numbers (`item1.TEL`) and types (`type=cell`) were not read. Contacts edited in Servant since stay as they are. |
| `backfill_n26_currency` | You imported N26 CSV files before October 2026: payments abroad held the foreign currency with the EUR amount, so Finance left them out of the totals. They become EUR, with the foreign currency kept as `original_currency`. |

## HTTPS and reverse proxy

Servant speaks plain HTTP on `PORT`; put a reverse proxy in front for TLS. With Caddy
(`Caddyfile`):

```
servant.local {
    reverse_proxy localhost:4000
}
```

Or use your nginx or Traefik. Either way:

- **WebSockets:** Phoenix Channels use `/socket`, so the proxy must pass the `Upgrade` and
  `Connection` headers (Caddy does).
- **`check_origin`:** if browsers cannot open the socket, set `PHX_HOST` to the exact public
  hostname.

## Invoice Collector (optional)

The Invoice Collector source runs Playwright scripts with `node` at each sync. For it, the
runtime stage of the `Dockerfile` copies Node.js 22 into `/opt/node`, installs the scraper
dependencies (`npm ci` in `priv/scrapers/`), and installs Chromium in `/opt/playwright` for the
unprivileged `nobody` user (Playwright starts it without its sandbox).

That block adds about 1 GB. Not using the source? Remove it with the `PLAYWRIGHT_BROWSERS_PATH`
and `PATH=/opt/node/bin` lines; its syncs then fail with "Node.js is not installed on the
server".

## Good to know

- **The first account is the operator:** it alone opens the Audit page (system health, access
  and error logs of all users). The data stays per user, for the operator too.
- **Files stay private:** `/files/…` (and the legacy `/uploads/…`) only serve their owner,
  through an HttpOnly `_servant_auth` cookie. `<img src="/files/…">` works, and JavaScript
  never sees a token.
- **Raspberry Pi:** the base images are multi-arch. To build on x86 for a Pi:
  `docker buildx build --platform linux/arm64 -t servant:latest .`
- **The web app is in the image:** after a frontend change, rebuild it. Production runs no
  Vite server.
- **The image** builds in three stages: `frontend` (`node:22`) builds the SPA, `build`
  (`hexpm/elixir`) makes the release, and `debian:bookworm-slim` runs it.
