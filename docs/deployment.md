# Docker Deployment

This guide describes how to deploy Servant as a single Docker image: an Elixir
release that serves both the JSON API and the pre-built Vue SPA on one port,
backed by a SQLite database on a mounted volume.

> Servant is API-only Phoenix + a Vue SPA. The SPA is built into `priv/static/`
> at image-build time and served by Phoenix, so the running container needs
> **no Node.js** — only the compiled release.

## Overview

The image is built in three stages:

1. **`frontend`** (`node:22`) — builds the Vue SPA into `priv/static/`.
2. **`build`** (`hexpm/elixir`) — compiles deps, digests assets, builds a `mix release`.
3. **runtime** (`debian:bookworm-slim`) — runs the release only.

At container start, an entrypoint runs pending Ecto migrations, then boots the
Phoenix server.

## Required files

Create the four files below at the repository root (plus one Elixir module).

### 1. `lib/servant/release.ex`

The release has no Mix available, so migrations run through a small module.
**This file is required** — the entrypoint calls `Servant.Release.migrate/0`.

```elixir
defmodule Servant.Release do
  @moduledoc "Release tasks (migrations) runnable without Mix."
  @app :servant

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

### 2. `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1

###############################################################################
# Stage 1 — build the Vue SPA into priv/static
###############################################################################
FROM node:22-bookworm-slim AS frontend

WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

# vite.config.ts writes the build to ../priv/static
COPY frontend/ ./
COPY priv/static/ /app/priv/static/
RUN npm run build

###############################################################################
# Stage 2 — build the Elixir release
###############################################################################
FROM hexpm/elixir:1.18.3-erlang-27.3.4-debian-bookworm-20260112-slim AS build

# Build tools for the exqlite NIF (SQLite is compiled in, no system sqlite needed)
RUN apt-get update -y \
    && apt-get install -y build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Dependencies first for better layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Application source
COPY config config
COPY priv priv
COPY lib lib

# SPA produced by the frontend stage (already in priv/static, digest it here)
COPY --from=frontend /app/priv/static ./priv/static

RUN mix compile
RUN mix phx.digest
RUN mix release

###############################################################################
# Stage 3 — minimal runtime
###############################################################################
FROM debian:bookworm-slim AS app

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Database lives on a mounted volume
RUN mkdir -p /data && chown nobody:nogroup /data
ENV DATABASE_PATH=/data/servant.db

COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/servant ./
COPY --chown=nobody:nogroup docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

USER nobody

ENV PHX_SERVER=true
ENV PORT=4000
EXPOSE 4000

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["bin/servant", "start"]
```

### 3. `docker-entrypoint.sh`

Runs migrations before every boot, then executes whatever `CMD` was given.

```sh
#!/bin/sh
set -e

# Apply any pending database migrations
/app/bin/servant eval "Servant.Release.migrate"

# Hand off to the release (CMD), e.g. `bin/servant start`
exec /app/"$@"
```

### 4. `.dockerignore`

Keeps the build context small and avoids leaking local artifacts.

```gitignore
_build/
deps/
.elixir_ls/
priv/static/assets/
frontend/node_modules/
frontend/dist/
*.db
*.db-*
.git/
.env
```

> Note: `priv/static/` is intentionally **not** ignored if you commit a built
> SPA, but here the `frontend` stage rebuilds it. The line above only ignores
> the digested `assets/` subfolder so a stale local digest isn't copied in.

### 5. `docker-compose.yml` (recommended)

```yaml
services:
  servant:
    build: .
    image: servant:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    environment:
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?run mix phx.gen.secret and put it in .env}
      PHX_HOST: ${PHX_HOST:-localhost}
      DATABASE_PATH: /data/servant.db
      PHX_SERVER: "true"
      PORT: "4000"
      # POOL_SIZE: "5"   # optional
    volumes:
      - servant_data:/data

volumes:
  servant_data:
```

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SECRET_KEY_BASE` | ✅ | — | Signs tokens/cookies. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | ✅ | `example.com` | Public hostname (used to build URLs). |
| `DATABASE_PATH` | ✅ | `/data/servant.db` (set in image) | Absolute path to the SQLite file — must be on the volume. |
| `FILES_DIR` | ✅ | `/data/files` (set in image) | Persistent user files (`apps/`, `connectors/`, `account/`). |
| `TMP_DIR` | ✅ | `/data/tmp` (set in image) | Scratch space for imports and processing (safe to purge). |
| `PHX_SERVER` | ✅ | `true` (set in image) | Must be truthy or the HTTP server won't start. |
| `PORT` | — | `4000` | HTTP listen port inside the container. |
| `POOL_SIZE` | — | `5` | SQLite connection pool size. |

## Deploy with docker-compose

```bash
# 1. Generate a secret and store it (compose reads .env automatically)
echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env
echo "PHX_HOST=servant.local" >> .env

# 2. Build and start
docker compose up -d --build

# 3. Follow logs
docker compose logs -f servant
```

Servant is now on `http://localhost:4000`. On first launch, open it, register
the first account, and add connectors.

## Deploy with plain Docker

If you don't want compose:

```bash
# Build
docker build -t servant:latest .

# Create a named volume for the database
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

## Operations

**Migrations** run automatically on every container start (via the entrypoint).
To run them manually:

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
  || echo "sqlite3 CLI not in image — use the file copy above when idle"
```

**Update to a new version:**

```bash
git pull
docker compose up -d --build   # rebuilds, restarts, runs new migrations
```

## HTTPS / reverse proxy

The container speaks plain HTTP on `PORT`. For TLS, put it behind a reverse
proxy. Example Caddy (`Caddyfile`):

```
servant.local {
    reverse_proxy localhost:4000
}
```

Add Caddy as a second compose service, or terminate TLS at an existing nginx/
Traefik in front of the `servant` service.

## Notes & gotchas

- **ARM / Raspberry Pi:** the base images (`node`, `hexpm/elixir`, `debian`)
  are multi-arch and build natively on `arm64`. To build on x86 for a Pi, use
  `docker buildx build --platform linux/arm64 -t servant:latest .`.
- **WebSockets:** Phoenix Channels use `/socket`. If you front Servant with a
  proxy, make sure it forwards `Upgrade`/`Connection` headers (Caddy does this
  automatically).
- **`check_origin`:** if browsers fail to connect over the socket behind a
  proxy, set `PHX_HOST` to the exact public hostname so origin checks pass.
- **The SPA is baked into the image.** Frontend changes require an image
  rebuild — there is no live Vite server in production.
```
