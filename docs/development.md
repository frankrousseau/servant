# Development Setup

For the coding rules and conventions, see [AGENTS.md](../AGENTS.md). For production
deployment, see [deploy.md](deploy.md).

## Prerequisites

1. Install [asdf](https://asdf-vm.com/).
2. Add the plugins:

   ```bash
   asdf plugin add erlang
   asdf plugin add elixir
   asdf plugin add nodejs
   ```

3. Install the versions pinned in `.tool-versions`:

   ```bash
   asdf install
   ```

The pinned versions are now:
- Erlang 29.0.3
- Elixir 1.20.2-otp-29
- Node.js 22.18.0

## Backend setup

```bash
mix setup
```

This command runs `deps.get`, makes the database and runs the migrations.

## Frontend setup

```bash
cd frontend
npm install
```

## Running in development

Run these commands from the project root.

**Terminal 1 (Phoenix API server, port 4001):**

```bash
mix phx.server
```

**Terminal 2 (Vite dev server, port 5001):**

```bash
cd frontend && npm run dev
```

Open `http://localhost:5001`. Vite sends the `/api` and `/socket` requests to Phoenix on port
4001. To change the ports, set `PORT` and `PHOENIX_PORT`.

### Seeding and switching databases

`mix servant.seed` fills the current dev database with random data for each app screen
(contacts, events, notes, checklists, trackers, bank transactions, invoices, files, generated
photos).

- On an empty database, it first makes a `demo` account (password `demo1234`).
- Otherwise, it uses the first account. Use `--user <name>` to select a different account.
- Use `--photos 0` to make no photos.

`DEV_DB=<name>` makes the backend use `servant_dev_<name>.db`. The backend makes and migrates
this file at start. To test the empty states:

```bash
DEV_DB=empty mix phx.server    # starts on servant_dev_empty.db (made at start)
mix phx.server                 # uses the usual servant_dev.db
```

You can use `DEV_DB` with the seed task (`DEV_DB=demo mix servant.seed`) to keep more than one
populated database.

### Docs screenshots

`frontend/scripts/screenshots.mjs` makes the README gallery (`docs/screenshots/*.webp`) and the
guide pictures (`docs/screenshots/guides/*.webp`) from a seeded temporary database. It uses
playwright-core with the local Chrome. To use a different Chromium, set `CHROME_PATH`.

```bash
DEV_DB=screenshots mix servant.seed --photos 30  # new file only: you cannot run the seed again
DEV_DB=screenshots PORT=4011 mix phx.server      # serves the built SPA (run cd frontend && npm run build first)
cd frontend && npm run screenshots               # all; or one group: npm run screenshots -- guides
```

The script logs in as `demo`, enables all the built-in apps and saves one 1440x900 WebP for
each README screen (group `readme`). For the guides (group `guides`), it first tags the photos,
names two contacts on them and turns agents on through the API. Then it crops each picture to
the part of the screen that the guide describes. To seed again, first delete
`servant_dev_screenshots.db`. The seed is random, so look at the screenshots before you commit
them.

## Project structure

This map shows the main subsystems, not all the files.

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
│   │   ├── api/               # Named calls per endpoint (entries, connectors, auth, photo shares)
│   │   ├── apps/              # Built-in apps (one folder each) + the AppContext contract
│   │   ├── components/        # Shared widgets (ComboBox, ServantDialog, LoadState, ...)
│   │   ├── composables/       # apiClient (the one HTTP client), useApi, useSocket, useConfirm
│   │   ├── lib/               # Shared helpers (datetime, entryRoute, kind, markdown, ...)
│   │   ├── stores/            # Pinia stores (auth, apps)
│   │   ├── views/             # Routed pages (dashboard, sources, settings, ...)
│   │   ├── router/
│   │   ├── style.css          # Design tokens and global styles
│   │   └── types.ts           # API response shapes (types only)
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

- **Connectors** are GenServers that sync data from external services. Each user has
  connector processes of their own. They implement the `Servant.Connectors.Connector`
  behaviour.
- **Agents** use one AI config for each user (`users.ai_config`, encrypted) and one
  `agent_runs` history (model, tokens, duration of each run). There are two types:
  - the **builder** (`Servant.Apps.Generator`): makes an installed custom app from a
    description;
  - **recurring agents** (`agents` table + `Servant.Agents.Scheduler`), with two modes. In
    prompt mode, the agent runs a prompt on a schedule over selected entries and makes
    `ai_report` entries. In **recipe** mode (`Servant.Agents.Recipe`), the model writes a
    deterministic recipe one time; each run uses zero tokens and makes `report` entries.

  The two types call one OpenAI-compatible endpoint (`Servant.AI`). Agents are off by default
  (Settings > Agents). Their UI is in the Agents section. This section is an optional app
  (Settings > Apps), off by default as all the non-default built-in apps.
- **Entries** contain all the data. Each item (transaction, photo, note, etc.) is an entry
  with a `kind`, a `source` and a JSON `data` payload.
- **Notes** are entries with `kind: "note"`. The `Servant.Notes` context manages them. When a
  note is saved, Servant reads its `[[wikilinks]]`, `@[[mentions]]` (contacts, events) and
  `#tags` into the `note_links` table (backlinks and graph). When a note gets a new name, the
  notes that refer to it are updated. The generic entries API cannot change notes; use
  `/api/notes`.
- **Connector secrets** are encrypted at rest (AES-256-GCM) with the `Servant.Encrypted.Map`
  Ecto type. The key comes from `CONNECTOR_ENCRYPTION_KEY` or `SECRET_KEY_BASE`.
- **All data queries use a `user_id` scope.** The API cannot give access to the data of a
  different user.
- **Phoenix.Token** gives authentication (bearer tokens or an HttpOnly cookie, 30 days
  maximum).
- **API tokens** (prefix `srv_`) have scopes: `app:<domain>:<read|write>`,
  `data:<read|write>`, and `data:read-binary` (explicit opt-in for raw `/files` downloads).
  Servant stores them hashed. You manage them in Settings.
- **OpenAPI docs**: the spec is at `/api/openapi.json`, SwaggerUI is at `/api/docs`.
- **Timestamps are in UTC** in the database. The frontend shows them in the `timezone`
  preference of the user.
- **PubSub** sends entry changes on the `"data:<user_id>"` topics (with `Servant.Events`).
  Phoenix Channels send them to the clients.
