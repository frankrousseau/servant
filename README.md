# Servant

A self-hosted personal data hub. Aggregates data from external services (email, banking, photos, health, etc.) via connectors and exposes it through a unified API and Vue.js web interface.

## Features

- **Universal data model** — all data stored as typed entries with JSON payloads
- **Connector plugin system** — pull data from external services on a schedule
- **Multi-user** — equal accounts, each with their own private data and connectors
- **Real-time** — Phoenix Channels push entry changes to connected clients
- **Self-hosted** — single binary deployment, SQLite database, runs on a Raspberry Pi

## Deployment

### Prerequisites

- Erlang 27+ and Elixir 1.18+
- Node.js 22+ (build-time only, not needed at runtime)

### Build a release

```bash
# Install dependencies
mix deps.get --only prod

# Build the Vue frontend
cd frontend && npm ci && npm run build && cd ..

# Compile and build the release
MIX_ENV=prod mix compile
MIX_ENV=prod mix phx.digest
MIX_ENV=prod mix release
```

The release is built to `_build/prod/rel/servant/`.

### Run the release

Three environment variables are required:

| Variable | Description | Example |
|----------|-------------|---------|
| `SECRET_KEY_BASE` | Signing key for tokens and cookies | Generate with `mix phx.gen.secret` |
| `DATABASE_PATH` | Absolute path to the SQLite database file | `/var/lib/servant/servant.db` |
| `PHX_HOST` | Public hostname | `servant.local` |

Optional variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listen port |
| `PHX_SERVER` | _(unset)_ | Set to `true` to start the HTTP server (required for releases) |
| `POOL_SIZE` | `5` | Database connection pool size |

```bash
SECRET_KEY_BASE=$(mix phx.gen.secret) \
DATABASE_PATH=/var/lib/servant/servant.db \
PHX_HOST=servant.local \
PHX_SERVER=true \
_build/prod/rel/servant/bin/servant start
```

The application will be available at `http://<PHX_HOST>:<PORT>`.

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
Environment=SECRET_KEY_BASE=<your-secret-key>

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now servant
```

### Reverse proxy (optional)

If you want HTTPS, put Servant behind nginx or Caddy. Example Caddy config:

```
servant.local {
    reverse_proxy localhost:4000
}
```

### First use

1. Open the application in a browser
2. Register the first user account
3. Add connectors from the Connectors page

All user accounts are equal — there is no admin/member hierarchy.
