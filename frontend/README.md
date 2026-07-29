# Servant — frontend

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
`/uploads` to the Phoenix server on port 4001 (see `vite.config.ts`). Start the
backend separately with `mix phx.server`; see [`docs/development.md`](../docs/development.md).

## Build

```bash
npm run build
```

Type-checks (`vue-tsc`) then builds into `../priv/static/`, which Phoenix serves
as the SPA in production.

## Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Vite dev server with API proxy |
| `npm run build` | Type-check + production build into `../priv/static` |
| `npm run preview` | Preview the production build locally |

## Structure

- `src/views/` — routed Vue views
- `src/apps/` — pluggable "apps" (photos, contacts, files, calendar, notes); see `src/apps/types.ts` for the `AppModule`/`AppContext` contract
- `src/composables/` — `useApi`, `useSocket`, …
- `src/stores/` — Pinia stores (`auth`)
- `public/` — static assets. `logo.svg` is the official logo (owl butler in a bow tie, monoline, drawn with `currentColor` so it inherits the surrounding text color); `favicon.svg` is the same mark with a thicker stroke so it stays legible at 16–32 px. The sidebar brand in `src/App.vue` inlines the same SVG and links back to the dashboard.
