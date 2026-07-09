# API tokens with scoped permissions + OpenAPI documentation

Date: 2026-07-10
Status: validated

## Goal

Let agents and scripts act on Servant data over the REST API with a restricted,
auditable, individually revocable credential, and give them a complete,
machine-readable OpenAPI description of the API.

## Decisions made

- Token mechanism: opaque tokens hashed in DB (GitHub PAT model), not signed
  Phoenix.Token (no individual revocation) and not OAuth2 (oversized for a
  personal instance).
- Scopes speak the app language (notes, trackers, finance...), not the internal
  entries model.
- App domains are namespaced under `app:`; `data:*` stays unprefixed.
- v1 surface: data domains + uploads. No connectors, no auth/profile, no audit.
- OpenAPI: open_api_spex (spec in code, always in sync), not a hand-written
  static file.

## 1. Scope model

Format: `app:<domain>:<action>` for app domains, `data:<action>` for the
transversal wildcard.

| Scope | Kinds covered |
|---|---|
| `app:notes:read/write` | `note` (writes go through `/api/notes` only, as today) |
| `app:checklists:read/write` | `checklist` |
| `app:calendar:read/write` | `event` |
| `app:contacts:read/write` | `contact` |
| `app:photos:read/write` | `photo` (+ upload with `app=photos`) |
| `app:files:read/write` | `file` (+ upload with `app=files`) |
| `app:finance:read/write` | `account`, `balance`, `bank_tx`, `blockchain_tx`, `invoice` |
| `app:trackers:read/write` | `tracker`, `tracker_log` |
| `data:read/write` | everything, including unmapped kinds (`health`, `activity`, `article`, `prefs`...) |

Rules:

- `write` implies `read` on the same domain.
- The kind-to-domain mapping lives in one module (`Servant.ApiTokens.Scopes`),
  single source of truth.
- A future kind that is not mapped is only reachable through `data:*`: safe by
  default.

## 2. Data model

Table `api_tokens`:

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `user_id` | fk users | |
| `name` | string | user-facing label |
| `token_hash` | string | SHA-256 of the plaintext, unique index |
| `prefix` | string | display hint, e.g. `srv_ab12` |
| `scopes` | JSON array | scope strings |
| `expires_at` | utc_datetime | nullable |
| `last_used_at` | utc_datetime | nullable, updated at most once per minute |
| timestamps | | |

Plaintext token: `srv_` + 32 random bytes base64url encoded. Shown exactly once
at creation, never stored.

## 3. Enforcement

- `ServantWeb.Auth` plug (extended): a Bearer token prefixed `srv_` is looked
  up by hash, expiry checked, then assigns `current_user` plus `:api_scopes`.
  Session tokens assign `api_scopes: nil` meaning full access; nothing changes
  for the SPA.
- Domain controllers (notes): `plug Scope, domain: :notes` (read for GET,
  write otherwise).
- EntryController, per kind: create/update/delete check the kind's domain;
  index restricts the query to allowed kinds; an explicit `?kind=` outside the
  token's scopes returns 403.
- Meta endpoints (`/entries/kinds`, `/entries/sources`, `/entries/stats`,
  `/entries/stats/daily`) and exports require `data:read` (they see everything
  by nature).
- Session-only (403 for any API token): `/auth/*` (profile, TOTP, password,
  avatar), connectors, audit, `backfill_media`, and token management itself
  (a token cannot create tokens: no privilege escalation).
- WebSocket: `srv_` tokens are rejected naturally (the socket verifies a
  Phoenix.Token); scripts use REST.
- Rate limiting: failed `srv_` lookups feed the existing `Servant.Auth.Throttle`
  keyed by IP.

Errors: 401 for an invalid or expired token; 403 with
`{"error": "Insufficient scope", "required": "app:trackers:write"}` for scope
failures.

## 4. Token management (endpoints + UI)

Endpoints, session-only:

- `GET /api/tokens`: list (name, prefix, scopes, created, last_used, expires;
  never the hash)
- `POST /api/tokens`: create, returns the plaintext once
- `DELETE /api/tokens/:id`: immediate revocation

UI in Settings, an "API tokens" card under the 2FA card: token list (name,
scope chips, last used, expiry) with a revoke button, a creation form (name +
per-domain read/write checkboxes + optional expiry). On creation the token is
shown in a mono block with a copy button and a "shown only once" warning.

## 5. OpenAPI (open_api_spex)

- Dependency `{:open_api_spex, "~> 3.21"}`.
- `ServantWeb.ApiSpec`: info, server, `securitySchemes` (bearer + cookie),
  tags per app.
- Schemas declared once (`Entry`, `Note`, `ApiToken`, `PaginationMeta`,
  `Error`...) and referenced everywhere.
- Every controller action annotated (`operation`: params, body, responses,
  required scopes documented in the description).
- Served at `GET /api/openapi.json` (public: the spec reveals the API shape,
  not user data) + SwaggerUI at `/api/docs`.
- Anti-drift guard: a test compares router routes to spec paths; adding an
  endpoint without annotating it fails `mix test`.
- v1 is documentation only; request validation from the spec is possible later
  but would change API behavior, so not now.

## 6. Tests

- Context: creation (hash stored, plaintext returned once), verification,
  expiry, revocation, throttled `last_used_at`.
- Auth plug: valid `srv_` token authenticates with scopes; invalid or expired
  gets 401; failures counted by the Throttle.
- Enforcement: `app:trackers:write` can create a `tracker_log` but not a
  `bank_tx` (403); index filtered to allowed kinds; `app:notes:read` can read
  `/api/notes` but not write; upload to `photos` denied without
  `app:photos:write`; session-only routes return 403 for an API token;
  `data:read` required for stats and exports; an API token cannot manage
  tokens.
- OpenAPI: the spec builds, is valid, and covers every router route.
