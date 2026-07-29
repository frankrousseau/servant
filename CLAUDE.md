# Servant

Self-hosted personal data hub: Elixir/Phoenix API-only backend + Vue.js 3 SPA (`frontend/`).
Aggregates data from external services via per-user connector GenServers, stores everything as
universal user-scoped `entries`, and pushes changes over Phoenix Channels.

## Coding rules & conventions

@AGENTS.md

## Development setup, project structure & architecture

@docs/development.md

## See also (not auto-loaded)

- `README.md`: short project overview, quick start, links to the docs.
- `docs/deploy.md`: deployment (Docker image/compose, bare-metal release, env vars, systemd, reverse proxy, ops).
- `docs/custom-apps.md`: apps installable from git (servant-app.json manifest, entry module contract).
- `docs/dav.md`: CalDAV/CardDAV/WebDAV endpoint at /dav (phone calendar + contacts sync, Files over WebDAV; client setup, what syncs, protocol subset).
- `docs/phone-backup.md`: user guide for auto-uploading a phone's camera roll to the Files app over WebDAV (PhotoSync, FolderSync, rclone).
- `specs/backlog.md`: ideas left over from shipped features ("hors scope v1"), nothing committed to.
