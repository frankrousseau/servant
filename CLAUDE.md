# Servant

Self-hosted personal data hub: Elixir/Phoenix API-only backend + Vue.js 3 SPA (`frontend/`).
Aggregates data from external services via per-user connector GenServers, stores everything as
universal user-scoped `entries`, and pushes changes over Phoenix Channels.

## Coding rules & conventions

@AGENTS.md

## Development setup, project structure & architecture

@DEVELOPMENT.md

## See also (not auto-loaded)

- `README.md`: deployment, release build, env vars, systemd/reverse-proxy.
- `docs/deployment.md`: Docker deployment (multi-stage build, compose, volumes, ops).
- `docs/PLAN.md`: original scaffolding plan (historical; the foundation it describes is already built).
- `docs/ai-agents-plan.md`: design notes for a future AI-agents feature (not yet implemented).
