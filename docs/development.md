# Development Setup

Coding rules and conventions live in [AGENTS.md](../AGENTS.md); production deployment is covered
in [deploy.md](deploy.md).

## Prerequisites

Install [asdf](https://asdf-vm.com/) and the required plugins:

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add nodejs
```

Then install the pinned versions from `.tool-versions`:

```bash
asdf install
```

This installs the versions pinned in `.tool-versions` (currently):
- Erlang 29.0.3
- Elixir 1.20.2-otp-29
- Node.js 22.18.0

## Backend setup

```bash
mix setup
```

This runs `deps.get`, creates the database, and runs migrations.

## Frontend setup

```bash
cd frontend
npm install
```

## Running in development

From the project root:

**Terminal 1 (Phoenix API server, port 4001):**

```bash
mix phx.server
```

**Terminal 2 (Vite dev server, port 5001):**

```bash
cd frontend && npm run dev
```

Open `http://localhost:5001` in your browser. Vite proxies `/api` and `/socket` requests to Phoenix on port 4001 (override with `PORT` / `PHOENIX_PORT`).

### Seeding and switching databases

`mix servant.seed` fills the current dev database with random but plausible data for every
app screen (contacts, events, notes, checklists, trackers, bank transactions, invoices,
files, generated photos). On an empty database it first creates a `demo` account
(password `demo1234`); otherwise it seeds the first account (`--user <name>` to pick
another one, `--photos 0` to skip photo generation).

`DEV_DB=<name>` switches the backend to `servant_dev_<name>.db`; the file is created and
migrated at boot, so testing the empty states is just:

```bash
DEV_DB=empty mix phx.server    # boots on servant_dev_empty.db (created on the fly)
mix phx.server                 # back to the regular servant_dev.db
```

`DEV_DB` composes with the seed task (`DEV_DB=demo mix servant.seed`) to maintain several
populated databases side by side.

## Project structure

Not exhaustive: a map of the main subsystems, not every file.

```
servant/
├── lib/
│   ├── servant/
│   │   ├── accounts/          # User schema (incl. timezone preference)
│   │   ├── accounts.ex        # Registration, authentication, TOTP
│   │   ├── api_tokens/        # Scoped `srv_` API token schema
│   │   ├── api_tokens.ex      # API token CRUD + scope model
│   │   ├── apps/              # Installed-app schema (git-installed custom apps)
│   │   ├── apps.ex            # Custom-app install/update from a git repo
│   │   ├── audit/            # Ring buffers + error log handler
│   │   ├── audit.ex           # System-health probes, cross-user access/error logs
│   │   ├── auth/              # Throttle (ETS anti-brute-force)
│   │   ├── caldav/, carddav/  # ICS / vCard codecs (round-trip raw payload)
│   │   ├── caldav.ex, carddav.ex, dav.ex  # DAV data access + ETag/CTag
│   │   ├── connectors/        # Connector behaviour, worker, scheduler, configs
│   │   ├── connectors.ex      # Connector config CRUD, start/stop
│   │   ├── data/              # Entry schema
│   │   ├── data.ex            # Entry CRUD (user-scoped)
│   │   ├── notes/             # NoteLink schema (wikilink/mention graph)
│   │   ├── notes.ex           # Notes context: wikilinks, backlinks, mentions, tags
│   │   ├── agent_memory.ex    # Agent memory context: path-keyed upserts for agent files
│   │   ├── encrypted/         # Ecto type for encrypted-at-rest maps
│   │   ├── encrypted.ex       # AES-256-GCM for connector secrets
│   │   ├── media/             # EXIF, thumbnails/display JPEGs (vix), rotation, backfill
│   │   ├── http.ex            # Req defaults + SSRF guard for connector fetches
│   │   ├── events.ex          # Shared PubSub broadcasting ("data:<user_id>")
│   │   └── storage.ex         # Per-user file storage layout
│   └── servant_web/
│       ├── controllers/       # Auth, Entry, Note, AgentMemory, Connector, Upload, Export, App, Files, Audit, Dav, SPA
│       ├── channels/          # UserSocket, DataChannel
│       ├── plugs/             # FileAuth, DavAuth, Scope, SessionOnly, RequireAdmin, AccessLog
│       ├── schemas/           # OpenApiSpex request/response schemas
│       ├── api_spec.ex        # OpenAPI spec generated from the router
│       ├── auth.ex            # Bearer/cookie auth plug
│       ├── router.ex          # API routes + SPA fallback
│       └── endpoint.ex
├── frontend/
│   ├── public/                # logo.svg (owl-butler logo), favicon.svg
│   ├── src/
│   │   ├── composables/       # useApi, useSocket
│   │   ├── stores/            # Pinia stores (auth)
│   │   ├── views/             # Vue views
│   │   ├── router/
│   │   └── types.ts
│   └── vite.config.ts
├── priv/
│   ├── repo/migrations/
│   └── static/                # Vue build output (gitignored)
└── config/
```

## Common tasks

| Task | Command |
|------|---------|
| Run tests | `mix test` |
| Reset database | `mix ecto.reset` |
| Seed random data | `mix servant.seed` |
| Boot on an empty database | `DEV_DB=empty mix phx.server` |
| Create a migration | `mix ecto.gen.migration <name>` |
| Run migrations | `mix ecto.migrate` |
| Build frontend for prod | `cd frontend && npm run build` |
| Phoenix console | `iex -S mix` |
| Format Elixir code | `mix format` |

## Architecture notes

- **Connectors** are GenServers that sync data from external services. Each user gets their own connector process. They implement the `Servant.Connectors.Connector` behaviour.
- **Agents** share one per-user AI config (`users.ai_config`, encrypted) and one `agent_runs` history (model, tokens, duration per run). Two types ship today: the **builder** (`Servant.Apps.Generator`, turns a description into an installed custom app) and **recurring agents** (`agents` table + `Servant.Agents.Scheduler`) in two modes: a prompt run on a schedule over selected entries producing `ai_report` entries, or a deterministic **recipe** (`Servant.Agents.Recipe`, drafted once by the model, zero tokens at run time) producing `report` entries. Both call one OpenAI-compatible endpoint (`Servant.AI`). Disabled by default (Settings > Agents); the UI lives in the Agents section, itself an optional app toggled in Settings > Apps (off by default, like any non-default built-in).
- **Entries** are the universal data container. Every piece of data (transaction, photo, note, etc.) is an entry with a `kind`, `source`, and JSON `data` payload.
- **Notes** are entries with `kind: "note"`, managed by the `Servant.Notes` context: `[[wikilinks]]`, `@[[mentions]]` (contacts/events) and `#tags` are parsed on save into the `note_links` table (backlinks + graph), and renames propagate to referring notes. Notes are intentionally **not** mutable through the generic entries API; edit them via `/api/notes`.
- **Connector secrets** are encrypted at rest (AES-256-GCM) via the `Servant.Encrypted.Map` Ecto type; the key derives from `CONNECTOR_ENCRYPTION_KEY` or `SECRET_KEY_BASE`.
- **All data queries are scoped by `user_id`**; there is no way to access another user's data through the API.
- **Phoenix.Token** is used for auth (bearer tokens or an HttpOnly cookie, 30-day max age).
- **API tokens** (`srv_` prefixed) are scoped (`app:<domain>:<read|write>`, `data:<read|write>`, plus the explicit `data:read-binary` opt-in for raw `/files` downloads), stored hashed, and managed from Settings.
- **OpenAPI docs** are served at `/api/openapi.json` (spec) and `/api/docs` (SwaggerUI).
- **Timestamps are stored in UTC**; the frontend renders them in the user's `timezone` preference.
- **PubSub** broadcasts entry changes on `"data:<user_id>"` topics (via `Servant.Events`), pushed to clients through Phoenix Channels.
