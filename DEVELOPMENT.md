# Development Setup

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

This gives you:
- Erlang 27.2.1
- Elixir 1.18.3
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

You need two terminals:

**Terminal 1 — Phoenix API server (port 4001):**

```bash
mix phx.server
```

**Terminal 2 — Vite dev server (port 5173):**

```bash
cd frontend
npm run dev
```

Open `http://localhost:5173` in your browser. Vite proxies `/api` and `/socket` requests to Phoenix on port 4001 (override with `PORT` / `PHOENIX_PORT`).

## Project structure

```
servant/
├── lib/
│   ├── servant/
│   │   ├── accounts/          # User schema (incl. timezone preference)
│   │   ├── accounts.ex        # Registration, authentication
│   │   ├── connectors/        # Connector behaviour, worker, scheduler, configs
│   │   ├── connectors.ex      # Connector config CRUD, start/stop
│   │   ├── data/              # Entry schema
│   │   ├── data.ex            # Entry CRUD (user-scoped)
│   │   ├── notes/             # NoteLink schema (wikilink/mention graph)
│   │   ├── notes.ex           # Notes context: wikilinks, backlinks, mentions, tags
│   │   ├── encrypted/         # Ecto type for encrypted-at-rest maps
│   │   ├── encrypted.ex       # AES-256-GCM for connector secrets
│   │   ├── media/             # EXIF extraction, thumbnail generation (vix)
│   │   ├── events.ex          # Shared PubSub broadcasting ("data:<user_id>")
│   │   └── storage.ex         # Per-user file storage layout
│   └── servant_web/
│       ├── controllers/       # Auth, Entry, Note, Connector, Upload, Export, App, Files, SPA
│       ├── channels/          # UserSocket, DataChannel
│       ├── plugs/             # FileAuth (cookie-authenticated /files)
│       ├── auth.ex            # Bearer/cookie auth plug
│       ├── router.ex          # API routes + SPA fallback
│       └── endpoint.ex
├── frontend/
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
| Create a migration | `mix ecto.gen.migration <name>` |
| Run migrations | `mix ecto.migrate` |
| Build frontend for prod | `cd frontend && npm run build` |
| Phoenix console | `iex -S mix` |
| Format Elixir code | `mix format` |

## Architecture notes

- **Connectors** are GenServers that sync data from external services. Each user gets their own connector process. They implement the `Servant.Connectors.Connector` behaviour.
- **Entries** are the universal data container. Every piece of data (transaction, photo, note, etc.) is an entry with a `kind`, `source`, and JSON `data` payload.
- **Notes** are entries with `kind: "note"`, managed by the `Servant.Notes` context: `[[wikilinks]]`, `@[[mentions]]` (contacts/events) and `#tags` are parsed on save into the `note_links` table (backlinks + graph), and renames propagate to referring notes. Notes are intentionally **not** mutable through the generic entries API — edit them via `/api/notes`.
- **Connector secrets** are encrypted at rest (AES-256-GCM) via the `Servant.Encrypted.Map` Ecto type; the key derives from `CONNECTOR_ENCRYPTION_KEY` or `SECRET_KEY_BASE`.
- **All data queries are scoped by `user_id`** — there is no way to access another user's data through the API.
- **Phoenix.Token** is used for auth (bearer tokens or an HttpOnly cookie, 30-day max age).
- **Timestamps are stored in UTC**; the frontend renders them in the user's `timezone` preference.
- **PubSub** broadcasts entry changes on `"data:<user_id>"` topics (via `Servant.Events`), pushed to clients through Phoenix Channels.
