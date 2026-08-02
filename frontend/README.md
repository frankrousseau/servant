# Servant, frontend

Vue 3 + TypeScript + Vite SPA for [Servant](../README.md). Talks to the Phoenix
API over `/api` and receives live entry updates over Phoenix Channels (`/socket`).

## Setup

```bash
npm install
```

## Develop

```bash
npm run dev
```

Runs Vite on <http://localhost:5001> and proxies `/api`, `/socket`, `/files` and
`/uploads` to the Phoenix server on port 4001 (override with `PHOENIX_PORT`; see
`vite.config.ts`). Start the backend separately with `mix phx.server`; see
[`docs/development.md`](../docs/development.md).

## Build

```bash
npm run build
```

Type-checks (`vue-tsc`) then builds into `../priv/static/`, which Phoenix serves
as the SPA in production. The build also copies the SwaggerUI assets out of
`swagger-ui-dist` into `../priv/static/swagger/`, so `/api/docs` works on an
instance with no internet access, and bakes the current commit and build date
into the bundle (shown in Settings).

## Test

```bash
npm test
```

Vitest on jsdom, tests colocated with the code as `*.test.ts` (see
`vitest.config.ts`).

## Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Vite dev server with API proxy |
| `npm run build` | Type-check + production build into `../priv/static` |
| `npm run preview` | Preview the production build locally |
| `npm test` | Run the test suite once |
| `npm run test:watch` | Run the tests in watch mode |
| `npm run format` | Prettier over `src/` and the root config files |
| `npm run format:check` | Prettier in check mode (no writes) |

## Structure

- `src/views/` - routed Vue views (dashboard, data browser, connectors, agents, audit, settings, profile, auth)
- `src/apps/` - pluggable "apps" (calendar, checklists, contacts, files, finance, notes, photos, trackers); see [`src/apps/README.md`](src/apps/README.md) and `src/apps/types.ts` for the `AppModule`/`AppContext` contract
- `src/components/` - `AppSidebar` (the shell's navigation) plus the shared widgets used by views and apps: `ComboBox`, `AutocompleteInput`, `ConfirmModal`, `DateInput`, `KindIcon`, `MediaViewer`, `VideoPlayer`, `CommandPalette`
- `src/composables/` - `apiClient` (the single HTTP client), `useApi`, `useSocket`, `useConfirm`, `useFetchData`, `authConfig`
- `src/lib/` - framework-free helpers (dates, markdown, theme, entry routes, upload queue, API token scopes)
- `src/stores/` - Pinia stores (`auth`, `apps`)
- `src/router/` - routes and navigation guards
- `public/` - static assets. `logo.svg` is the official logo (owl butler in a bow tie, monoline, drawn with `currentColor` so it inherits the surrounding text color); `favicon.svg` is the same mark with a thicker stroke so it stays legible at 16-32 px. The sidebar brand in `src/components/AppSidebar.vue` inlines the same SVG and links back to the dashboard (which is why the sidebar has no dashboard entry). `models/` holds the face-api weights the Photos app loads for on-device face detection.
