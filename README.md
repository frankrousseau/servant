# Servant, personal data hub you control

A self-hosted personal data hub that aggregates data from external services (banking, photos, health,
calendar, contacts, blockchain, etc.) via connectors and exposes it through a unified API and a web interface.

## Features

- **Universal data model**: all data stored as typed entries with JSON payloads
- **Connector plugin system**: pull data from external services on a schedule
- **Single-user**: All UIs are designed for personal usages
- **API access**: scoped, revocable tokens for scripts and agents
- **Real-time**: entry changes are pushed to connected clients over websockets
- **Self-hosted**: single binary deployment, SQLite database, runs on a Raspberry Pi

## Quick start

Run it with Docker (the repo ships a `Dockerfile` and a `docker-compose.yml`):

```bash
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" >> .env
echo "PHX_HOST=localhost" >> .env
docker compose up -d --build
```

Open `http://localhost:4000` and register the first account. See
[docs/deploy.md](docs/deploy.md) for bare-metal releases, environment variables, systemd, reverse proxies and backups.

## Development

```bash
mix setup                   # deps, database, migrations
cd frontend && npm install
```

```bash
mix phx.server              # API on port 4001
cd frontend && npm run dev  # frontend on port 5001
```

Open `http://localhost:5001`. See [docs/development.md](docs/development.md) for prerequisites,
project structure and architecture notes.

## Documentation

- [docs/deploy.md](docs/deploy.md): deployment (Docker, release, env vars, ops)
- [docs/backup-strategy.md](docs/backup-strategy.md): what to back up, recipes, restore procedure
- [docs/development.md](docs/development.md): dev setup, project structure, architecture
- [docs/dav.md](docs/dav.md): CalDAV/CardDAV/WebDAV endpoint (phone calendar, contacts, files)
- [docs/phone-backup.md](docs/phone-backup.md): auto-upload a phone's camera roll to the Files app
- [docs/photo-sharing.md](docs/photo-sharing.md): share a photo feed by public link from one or more tags
- [docs/custom-apps.md](docs/custom-apps.md): apps installable from git
- [AGENTS.md](AGENTS.md): coding rules and conventions
