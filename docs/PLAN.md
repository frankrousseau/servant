# Servant: Initial Scaffolding Plan

## Context

Servant is a greenfield, self-hosted personal data hub built with Elixir/Phoenix (API) + Vue.js 3 (SPA). It aggregates personal data from external services (Gmail, banks, photos, health data, etc.) via a connector plugin system, and exposes it through built-in and client-only apps that all share the same API.

**Multi-user model:** Equal accounts with no hierarchy. Each user manages their own connectors and data. Data is private by default; sharing is explicit (future feature). Each user connects their own services (Gmail, bank, etc.).

The goal of this plan is to scaffold the project foundation: Phoenix backend, Vue frontend, core data model, connector behaviour, app interface, and auth.

---

## Decision: Monorepo with Vue inside Phoenix

Vue frontend lives at `frontend/` inside the Phoenix project. In production, Phoenix serves the built SPA from `priv/static/`. In dev, Vite runs on its own port with proxy to Phoenix for `/api` and `/socket`.

**Why:** Single repo, single deployment artifact, simplest for self-hosted on a Raspberry Pi.

---

## Implementation Steps

### Step 1: Install Toolchain
- Erlang 27 + Elixir 1.18 (via asdf or system packages)
- Phoenix 1.8 generator: `mix archive.install hex phx_new`
- Create `.tool-versions` to pin versions

### Step 2: Generate Phoenix Project
```bash
mix phx.new servant --no-html --no-assets --no-live --no-mailer --database sqlite3
```
API-only Phoenix with SQLite, no HTML/LiveView/assets.

### Step 3: Verify Phoenix Runs
```bash
mix deps.get && mix ecto.create && mix phx.server
```

### Step 4: Create Vue Frontend
```bash
npm create vite@latest frontend -- --template vue-ts
cd frontend && npm install vue-router@4 pinia @vueuse/core
```

### Step 5: Wire Vite to Phoenix
- `frontend/vite.config.ts`: build output to `../priv/static`, proxy `/api` and `/socket` to `localhost:4000`
- Mix alias `assets.deploy` to run `npm run build` in frontend/
- SPA fallback route in Phoenix router (catch-all → `index.html`)

### Step 6: Core Database Migrations

**`users` table:**
| Column | Type | Purpose |
|--------|------|---------|
| `username` | string | unique identifier for login |
| `hashed_password` | string | bcrypt hash |
| `display_name` | string | shown in UI |
| timestamps | | |

**`entries` table** (universal data container):
| Column | Type | Purpose |
|--------|------|---------|
| `user_id` | references(users) | owner of this entry |
| `kind` | string | "email", "transaction", "photo", "contact", etc. |
| `source` | string | connector that created it ("gmail", "manual") |
| `external_id` | string | dedupe key from source |
| `title` | string | human-readable summary |
| `occurred_at` | utc_datetime | when the event happened |
| `data` | map (JSONB) | all source-specific fields |
| `metadata` | map (JSONB) | tags, flags, user state |

Indexes on `[user_id, kind]`, `[user_id, source]`, `[user_id, occurred_at]`. Unique index on `(user_id, source, external_id)`.

**`credentials` table** (encrypted OAuth/API keys):
| Column | Type | Purpose |
|--------|------|---------|
| `user_id` | references(users) | owner |
| `connector_type` | string | e.g. "gmail", "bank_x" |
| `data` | binary | encrypted credential blob (cloak_ecto) |
| timestamps | | |

**`connector_configs` table** (per-user connector state):
| Column | Type | Purpose |
|--------|------|---------|
| `user_id` | references(users) | owner |
| `connector_type` | string | which connector |
| `enabled` | boolean | is it running? |
| `config` | map (JSONB) | connector-specific settings |
| `last_synced_at` | utc_datetime | last successful sync |
| `error` | string | last error, if any |
| timestamps | | |

**`settings` table**: key/value for system and per-user config.

### Step 7: Auth System
- Registration: `POST /api/auth/register` (username + password), open to any user on the instance
- First user created becomes the instance (can be refined later if needed)
- Login: `POST /api/auth/login` → returns signed Phoenix.Token
- Auth plug: validates bearer token on all `/api/*` routes, scopes all queries to current user
- Password hashing: `bcrypt_elixir`
- All data queries automatically scoped by `user_id`

### Step 8: Data Context
- CRUD for entries, always scoped to current user
- Filtering by `kind`, `source`, date range
- JSON field queries via `fragment/1` (works on both SQLite and Postgres)

### Step 9: API Controllers + JSON Renderers
| Endpoint | Purpose |
|----------|---------|
| `POST /api/auth/register` | Create account |
| `POST /api/auth/login` | Login |
| `GET/POST/PUT/DELETE /api/entries` | Entry CRUD (user-scoped) |
| `GET /api/entries/kinds` | List distinct kinds (user-scoped) |
| `GET /api/apps` | List registered apps |
| `GET/POST/PUT/DELETE /api/connectors` | Connector config CRUD (user-scoped) |
| `POST /api/connectors/:id/start` | Start a connector |
| `POST /api/connectors/:id/stop` | Stop a connector |
| `GET /api/connectors/:id/logs` | Connector logs |

### Step 10: Connector Behaviour
```elixir
@callback id() :: String.t()
@callback name() :: String.t()
@callback required_credentials() :: [atom()]
@callback kind() :: String.t()
@callback init(credentials :: map(), config :: map()) :: {:ok, state} | {:error, term()}
@callback sync(state) :: {sync_result(), state}
@callback schedule() :: non_neg_integer()
```

Each connector GenServer is started per-user: if 3 users enable Gmail, there are 3 Gmail GenServer processes, each with their own credentials.

### Step 11: Connector Supervision
- `DynamicSupervisor` for connector GenServers
- `Registry` (ETS-backed) tracking `{user_id, connector_type}` → pid
- `Scheduler` GenServer: starts enabled connectors for all users on boot
- Connectors report state via PubSub (scoped by user)

### Step 12: Example Connector
A trivial connector (e.g., RSS feed reader) to prove the pattern.

### Step 13: Phoenix Channels
- `DataChannel` broadcasting entry create/update/delete events via PubSub
- User-scoped topics: `"data:#{user_id}"` (users only receive their own events)

### Step 14: Vue Shell
- Router, auth store (Pinia), API composable, socket composable
- Views: Login, Register, Dashboard, Data Browser, Connectors, Settings
- App loading system: built-in apps at `frontend/src/apps/{file-manager,calendar,contacts}/`

### Step 15: App Manifest System
- App manifests (id, name, kind_filter, entry_point, icon)
- `GET /api/apps` serves the list
- Built-in apps consume the same `/api/entries` endpoints as external apps

---

## Supervision Tree

```
Servant.Application
├── Servant.Repo (SQLite)
├── Phoenix.PubSub
├── ServantWeb.Endpoint
├── Servant.Connectors.Registry
├── Servant.Connectors.Supervisor (DynamicSupervisor)
└── Servant.Connectors.Scheduler
```

---

## Key Design Decisions

- **Multi-user, equal accounts**: No admin/member hierarchy. All users are peers with their own private data space.
- **Per-user connectors**: Each user connects their own services. Connector GenServers run per-user.
- **Data scoping**: All queries automatically scoped by `user_id`. No cross-user data access (sharing is a future feature).
- **Credential encryption**: Use `cloak_ecto` for at-rest encryption of OAuth tokens
- **File storage**: Store only metadata in DB; actual files on disk with path in `data` field
- **SQLite WAL mode**: Default in `ecto_sqlite3`, handles concurrent reads well
- **DB-agnostic**: Keep SQL dialect details in context modules, use Ecto abstractions

---

## Verification

1. `mix phx.server` starts without errors
2. Register a user via `POST /api/auth/register`
3. Login returns a valid token; authenticated requests succeed
4. CRUD operations on `/api/entries` work with JSONB data and are user-scoped
5. Second user cannot see first user's data
6. Vue dev server proxies to Phoenix correctly
7. `mix assets.deploy` builds Vue into `priv/static/` and Phoenix serves it
8. Example connector starts per-user, syncs, and creates entries scoped to that user
