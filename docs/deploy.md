# Deployment

Servant is one Elixir release. It serves the JSON API and the pre-built SPA on one port. It
keeps its data in one SQLite file. You can run it in two ways:

- **[Docker](#docker-recommended)** (recommended). The repo contains the `Dockerfile`,
  `docker-compose.yml` and `docker-entrypoint.sh`. Migrations run when the container starts.
- **[Bare metal](#bare-metal-release)**. You build a `mix release` and run it with systemd.

Read [Environment variables](#environment-variables) first. If `DATABASE_PATH` or `FILES_DIR`
is incorrect, a redeploy deletes your data.

## Docker (recommended)

The image has three build stages:

1. **`frontend`** (`node:22`): builds the SPA into `priv/static/`.
2. **`build`** (`hexpm/elixir`): compiles the deps, digests the assets and builds a `mix release`.
3. **runtime** (`debian:bookworm-slim`): runs the release.

When the container starts, `docker-entrypoint.sh` runs the pending Ecto migrations
(`Servant.Release.migrate/0`). Then it starts the Phoenix server. The image sets
`DATABASE_PATH=/data/servant.db`, `FILES_DIR=/data/files` and `TMP_DIR=/data/tmp` on the
mounted volume. You must set only `SECRET_KEY_BASE` and `PHX_HOST`.

> The release does not need Node.js at runtime. The image contains Node and Chromium only for
> the optional Invoice Collector connector. To remove them, see
> [Invoice Collector](#invoice-collector-optional).

### With docker-compose

```bash
# 1. Make a secret and keep it in .env (compose reads .env)
echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env
echo "PHX_HOST=servant.local" >> .env

# 2. Build and start
docker compose up -d --build

# 3. Show the logs
docker compose logs -f servant
```

Open `http://localhost:4000`, register the first account, then add connectors.

### With plain Docker

```bash
docker build -t servant:latest .
docker volume create servant_data

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

- Erlang 29+ and Elixir 1.20+ (the pinned versions are in `.tool-versions`).
- Node.js 22+ to build the frontend. The **Invoice Collector** connector also needs Node.js
  at runtime: it runs Playwright scripts with `node` (run `npm install` in `priv/scrapers/`).
- `libvips` at runtime, for photo thumbnails (`vix`). Use a `libvips` with `libheif` to get
  previews of HEIC photos. Most distribution packages have it.

### Build

```bash
mix deps.get --only prod

# Build the frontend (vite writes into priv/static/)
cd frontend && npm ci && npm run build && cd ..

MIX_ENV=prod mix compile
MIX_ENV=prod mix phx.digest
MIX_ENV=prod mix release
```

The release is in `_build/prod/rel/servant/`.

### Run

```bash
SECRET_KEY_BASE=$(mix phx.gen.secret) \
DATABASE_PATH=/var/lib/servant/servant.db \
FILES_DIR=/var/lib/servant/files \
PHX_HOST=servant.local \
PHX_SERVER=true \
_build/prod/rel/servant/bin/servant start
```

The application is at `http://<PHX_HOST>:<PORT>`. Migrations do not run automatically. After
each upgrade, run them:

```bash
_build/prod/rel/servant/bin/servant eval "Servant.Release.migrate"
```

### Systemd service

Make `/etc/systemd/system/servant.service`:

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

> ⚠️ **Keep your data.** Set `DATABASE_PATH` **and** `FILES_DIR` to a location outside the
> release directory (a Docker volume or `/var/lib/servant/`). If you do not, each redeploy
> deletes the database and the user files.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SECRET_KEY_BASE` | ✅ | _(none)_ | Signs tokens and cookies. Make it with `mix phx.gen.secret`. |
| `PHX_HOST` | ✅ | `example.com` | Public hostname. Used in URLs and in the socket origin check. |
| `PHX_SERVER` | ✅ | `true` in the Docker image | Set to true, or the HTTP server does not start. |
| `DATABASE_PATH` | ✅ | `/data/servant.db` in the Docker image | Absolute path to the SQLite file. Use persistent storage. |
| `FILES_DIR` | ✅ in practice | `/data/files` in the Docker image, else `priv/files` | Uploaded files, photos and connector archives. **Set it outside the release.** The default is in the release directory, and **each redeploy deletes it**. |
| `TMP_DIR` | | `/data/tmp` in the Docker image, else `priv/tmp` | Temporary space for connector file imports. You can delete its contents. |
| `PORT` | | `4000` | HTTP port. |
| `POOL_SIZE` | | `5` | Number of SQLite connections. |
| `REGISTRATION_ENABLED` | | `true` | Set to `false` to stop new registrations. Existing users can log in. |
| `AGENT_CONCURRENCY` | | `1` | Maximum number of agents that run at the same time. Use `1` for a self-hosted model server. Use a larger value for a hosted API. |
| `CONNECTOR_ENCRYPTION_KEY` | | _(derived from `SECRET_KEY_BASE`)_ | Encrypts connector secrets at rest (AES-256-GCM). Set it to change this key independently of `SECRET_KEY_BASE`. **If this key changes (or `SECRET_KEY_BASE` when this key is not set), Servant cannot decrypt the stored connector secrets. You must enter them again.** |
| `UPLOADS_DIR` | | `priv/uploads` | Legacy uploads directory. Servant only reads it, for files older than `FILES_DIR`. |

## Operations

**Migrations** run each time the container starts. To run them manually:

```bash
docker compose exec servant bin/servant eval "Servant.Release.migrate"
```

**Photo EXIF backfill** (one time). HEIC photos (iPhone) imported before HEIC EXIF support
have no date and no location. This command reads them again. It does not change stored values:

```bash
docker compose exec servant bin/servant eval "Servant.Release.backfill_photo_exif"
```

**CardDAV contact backfill** (one time). Before October 2026, Servant did not read some
iPhone phone numbers (`item1.TEL`) and types (`type=cell`). This command reads the stored
cards again. It does not change a contact that you edited in Servant after the phone sync:

```bash
docker compose exec servant bin/servant eval "Servant.Release.backfill_carddav_contacts"
```

**Remote IEx console** on the running release:

```bash
docker compose exec servant bin/servant remote
```

**Database backup.** Use the SQLite backup command. It makes a consistent copy while Servant
runs:

```bash
docker compose exec servant sh -c \
  'sqlite3 /data/servant.db ".backup /data/servant-backup.db"'
docker cp servant:/data/servant-backup.db ./servant-backup.db
```

If the image does not contain `sqlite3`, stop Servant before you copy `servant.db`. Also back
up `FILES_DIR` (`/data/files`): the database does not contain the uploaded files. For the full
procedure, see [backup-strategy.md](backup-strategy.md).

**Update to a new version:**

```bash
git pull
docker compose up -d --build   # rebuilds, restarts, runs the new migrations
```

## HTTPS / reverse proxy

Servant uses plain HTTP on `PORT`. For TLS, put a reverse proxy in front of it. Caddy example
(`Caddyfile`):

```
servant.local {
    reverse_proxy localhost:4000
}
```

Add Caddy as a second compose service, or use your existing nginx or Traefik.

## Invoice Collector (optional)

The Invoice Collector connector runs Playwright scripts with `node` during each sync. For this
connector, stage 3 of the Dockerfile:

- copies Node.js 22 from the frontend stage into `/opt/node`,
- installs the scraper dependencies (`npm ci` in `priv/scrapers/` of the release),
- installs the Playwright Chromium in `/opt/playwright`, readable by the `nobody` user.

Playwright starts Chromium without its sandbox, so it runs as an unprivileged user.

This block adds approximately 1 GB to the image. If you do not use the connector, remove it and
the `PLAYWRIGHT_BROWSERS_PATH` and `PATH=/opt/node/bin` lines. Invoice Collector syncs then stop
with the error "Node.js is not installed on the server".

## Notes

- **File access.** Servant serves uploaded files under `/files/…` (and legacy `/uploads/…`)
  **only to their owner**. An HttpOnly `_servant_auth` cookie, set at login, gives access to
  `FILES_DIR/<user_id>/`. Thus `<img src="/files/…">` works, and JavaScript does not see a
  token.
- **The first account is the operator.** Only this account can open the Audit page (system
  health, access and error logs of all users). The data stays per user, also for the operator:
  the API cannot read the entries of a different account.
- **ARM / Raspberry Pi.** The base images (`node`, `hexpm/elixir`, `debian`) are multi-arch and
  build on `arm64`. To build on x86 for a Pi, use
  `docker buildx build --platform linux/arm64 -t servant:latest .`.
- **WebSockets.** Phoenix Channels use `/socket`. Make sure that your proxy sends the `Upgrade`
  and `Connection` headers. Caddy does this automatically.
- **`check_origin`.** If browsers cannot connect to the socket behind a proxy, set `PHX_HOST`
  to the exact public hostname.
- **The SPA is in the image.** After a frontend change, build the image again. Production has
  no Vite server.
