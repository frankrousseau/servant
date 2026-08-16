# Deployment

Servant ships as a single Elixir release that serves both the JSON API and the pre-built SPA on
one port, backed by a SQLite database file. Two supported ways to run it:

- **[Docker](#docker-recommended)** (recommended): everything is in the repo (`Dockerfile`,
  `docker-compose.yml`, `docker-entrypoint.sh`), migrations run at container start.
- **[Bare metal](#bare-metal-release)**: build a `mix release` yourself and run it under systemd.

Either way, read [Environment variables](#environment-variables) first: two paths
(`DATABASE_PATH` and `FILES_DIR`) decide whether your data survives a redeploy.

## Docker (recommended)

The image is built in three stages:

1. **`frontend`** (`node:22`): builds the SPA into `priv/static/`.
2. **`build`** (`hexpm/elixir`): compiles deps, digests assets, builds a `mix release`.
3. **runtime** (`debian:bookworm-slim`): runs the release only.

At container start, `docker-entrypoint.sh` runs pending Ecto migrations
(`Servant.Release.migrate/0`), then boots the Phoenix server. The image already sets
`DATABASE_PATH=/data/servant.db`, `FILES_DIR=/data/files` and `TMP_DIR=/data/tmp`, all on the
mounted volume, so only `SECRET_KEY_BASE` and `PHX_HOST` are left to you.

> The release itself needs no Node.js at runtime. The image does ship Node + Chromium, but only
> for the optional Invoice Collector connector; see
> [Invoice Collector](#invoice-collector-optional) to drop them.

### With docker-compose

```bash
# 1. Generate a secret and store it (compose reads .env automatically)
echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env
echo "PHX_HOST=servant.local" >> .env

# 2. Build and start
docker compose up -d --build

# 3. Follow logs
docker compose logs -f servant
```

Servant is now on `http://localhost:4000`. On first launch, open it, register the first account,
and add connectors.

### With plain Docker

```bash
# Build
docker build -t servant:latest .

# Create a named volume for the database and files
docker volume create servant_data

# Run
docker run -d --name servant \
  -p 4000:4000 \
  -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  -e PHX_HOST="servant.local" \
  -v servant_data:/data \
  --restart unless-stopped \
  servant:latest
```

## Bare metal (release)

### Prerequisites

- Erlang 29+ and Elixir 1.20+ (pinned versions in `.tool-versions`)
- Node.js 22+: required to build the frontend. Also required **at runtime** if you use the
  **Invoice Collector** connector, which runs Playwright scripts via `node` (run `npm install`
  in `priv/scrapers/`). Not needed at runtime otherwise.
- `libvips`: required at runtime for photo thumbnail generation (`vix`). Build it with
  `libheif` (the distro packages usually do) to also get previews for HEIC photos
  uploaded over `/dav/photos`.

### Build

```bash
# Install dependencies
mix deps.get --only prod

# Build the frontend (vite writes into priv/static/)
cd frontend && npm ci && npm run build && cd ..

# Compile and build the release
MIX_ENV=prod mix compile
MIX_ENV=prod mix phx.digest
MIX_ENV=prod mix release
```

The release is built to `_build/prod/rel/servant/`.

### Run

```bash
SECRET_KEY_BASE=$(mix phx.gen.secret) \
DATABASE_PATH=/var/lib/servant/servant.db \
FILES_DIR=/var/lib/servant/files \
PHX_HOST=servant.local \
PHX_SERVER=true \
_build/prod/rel/servant/bin/servant start
```

The application is available at `http://<PHX_HOST>:<PORT>`. Migrations do not run on their own
here; apply them after each upgrade:

```bash
_build/prod/rel/servant/bin/servant eval "Servant.Release.migrate"
```

### Systemd service

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
Environment=SECRET_KEY_BASE=<your-secret-key>

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now servant
```

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SECRET_KEY_BASE` | ✅ | _(none)_ | Signs tokens and cookies. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | ✅ | `example.com` | Public hostname (used to build URLs and check socket origins). |
| `PHX_SERVER` | ✅ | `true` in the Docker image | Must be truthy or the HTTP server won't start. |
| `DATABASE_PATH` | ✅ | `/data/servant.db` in the Docker image | Absolute path to the SQLite file. Must live on persistent storage. |
| `FILES_DIR` | ✅ in practice | `/data/files` in the Docker image, else `priv/files` | Uploaded files, photos and connector archives. **Set this outside the release**; the default lives inside the release directory and is **wiped on every redeploy**. |
| `TMP_DIR` | | `/data/tmp` in the Docker image, else `priv/tmp` | Scratch space used while importing connector files (safe to purge). |
| `PORT` | | `4000` | HTTP listen port. |
| `POOL_SIZE` | | `5` | SQLite connection pool size. |
| `REGISTRATION_ENABLED` | | `true` | Set to `false` to close self-registration (e.g. after creating your accounts). Existing users can still log in. |
| `AGENT_CONCURRENCY` | | `1` | How many due agents may run at once. One suits a self-hosted model server (they usually serve a single request at a time); raise it when the endpoint is a hosted API. |
| `CONNECTOR_ENCRYPTION_KEY` | | _(derived from `SECRET_KEY_BASE`)_ | Key used to encrypt connector secrets at rest (AES-256-GCM). Set a dedicated value to rotate it independently of `SECRET_KEY_BASE`. **Changing this key (or `SECRET_KEY_BASE` when it's unset) makes stored connector secrets undecryptable; you must re-enter them.** |
| `UPLOADS_DIR` | | `priv/uploads` | Legacy uploads directory (only read, for files created before `FILES_DIR`). |

> ⚠️ **Persist your data.** Both `DATABASE_PATH` **and** `FILES_DIR` must point outside the
> release directory (a Docker volume, or e.g. `/var/lib/servant/`), or you lose user files and
> the database on each redeploy.

## Operations

**Migrations** run automatically on every container start (via the entrypoint). To run them
manually:

```bash
docker compose exec servant bin/servant eval "Servant.Release.migrate"
```

**Open a remote IEx console** on the running release:

```bash
docker compose exec servant bin/servant remote
```

**Back up the database** (SQLite is a single file on the volume):

```bash
docker compose exec servant sh -c 'cp /data/servant.db /data/servant-backup.db'
docker cp servant:/data/servant-backup.db ./servant-backup.db
```

For a consistent online backup, prefer SQLite's own command:

```bash
docker compose exec servant sh -c \
  'sqlite3 /data/servant.db ".backup /data/servant-backup.db"' 2>/dev/null \
  || echo "sqlite3 CLI not in image; use the file copy above when idle"
```

Back up `FILES_DIR` (`/data/files`) too: the database alone does not contain uploaded files.

**Update to a new version:**

```bash
git pull
docker compose up -d --build   # rebuilds, restarts, runs new migrations
```

## HTTPS / reverse proxy

Servant speaks plain HTTP on `PORT`. For TLS, put it behind a reverse proxy. Example Caddy
(`Caddyfile`):

```
servant.local {
    reverse_proxy localhost:4000
}
```

Add Caddy as a second compose service, or terminate TLS at an existing nginx/Traefik in front of
the `servant` service.

## Invoice Collector (optional)

The Invoice Collector connector runs Playwright scripts via `node` at sync time, so stage 3 of
the Dockerfile copies Node.js 22 from the frontend stage into `/opt/node`, installs the scraper
dependencies (`npm ci` in the release's `priv/scrapers/`) and Playwright's Chromium (under
`/opt/playwright`, readable by the `nobody` user). Playwright launches Chromium with its sandbox
disabled by default, so it runs fine as an unprivileged user.

This block is the only reason the runtime image contains Node.js, and it accounts for roughly
1 GB. If you do not use the connector, delete it (and the `PLAYWRIGHT_BROWSERS_PATH` /
`PATH=/opt/node/bin` lines) for a slim image; Invoice Collector syncs then fail with an explicit
"Node.js is not installed on the server" error instead of running.

## Notes & gotchas

- **File access:** uploaded files are served under `/files/…` (and legacy `/uploads/…`) **only to
  their owner**. Access is authenticated by an HttpOnly `_servant_auth` cookie set at login and
  scoped to `FILES_DIR/<user_id>/`, so `<img src="/files/…">` works without exposing a token to
  JavaScript.
- **First account is the operator:** it alone can open the Audit page (system health, cross-user
  access and error logs). Data itself stays scoped per user, operator included: there is no way
  to read another account's entries through the API.
- **ARM / Raspberry Pi:** the base images (`node`, `hexpm/elixir`, `debian`) are multi-arch and
  build natively on `arm64`. To build on x86 for a Pi, use
  `docker buildx build --platform linux/arm64 -t servant:latest .`.
- **WebSockets:** Phoenix Channels use `/socket`. If you front Servant with a proxy, make sure it
  forwards `Upgrade`/`Connection` headers (Caddy does this automatically).
- **`check_origin`:** if browsers fail to connect over the socket behind a proxy, set `PHX_HOST`
  to the exact public hostname so origin checks pass.
- **The SPA is baked into the image.** Frontend changes require an image rebuild; there is no
  live Vite server in production.
