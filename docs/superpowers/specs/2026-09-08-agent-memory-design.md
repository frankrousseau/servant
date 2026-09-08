# Agent memory app

Store the memory and skills of coding agents (Claude Code, Cursor) in Servant so two
machines (desktop, laptop) share them. The agents themselves push and pull through a
dedicated API, guided by a skill and an API token; Servant never touches the local
filesystem. Memory files are readable and editable in a Notes-like app.

## Data model

One entry per file: `kind: "agent_memory"`, `source: "agent"` (the UI writes through the
same endpoint, so the source never varies), `external_id` = path (the existing
`user_id + source + external_id` unique index enforces path uniqueness), `title` = file
name (last path segment), `data`:

| key | value |
|-----|-------|
| `path` | canonical path, unique per user (see below) |
| `body` | raw markdown, frontmatter included and not parsed |
| `project` | repo root folder name (`servant-elixir`), `""` for global files |
| `tool` | `claude`, `cursor` or `shared` |
| `sha256` | hex digest of `body`, computed server side |

Paths are the only identity the agent needs; `project` and `tool` derive from them:

| path | project | tool |
|------|---------|------|
| `memory/<project>/<file>.md` (incl. `MEMORY.md`) | `<project>` | `claude` |
| `skills/<tool>/<name>/SKILL.md` (and sibling files) | `""` | `<tool>` |
| `rules/<project>/<file>.mdc` | `<project>` | `cursor` |

Validation: prefix in `memory/`, `skills/`, `rules/`; every segment matches
`^[A-Za-z0-9._-]+$` and is neither `.` nor `..`; at least the segments the table
requires; body is a string. Anything else is rejected with 422. `tool` in `skills/`
must be `claude`, `cursor` or `shared`.

No migration: entries already carry a JSON `data` column. 

## API

Scope domain `agent_memory` (added to `Servant.ApiTokens.Scopes`: `@app_domains` and
`"agent_memory" => "agent_memory"` in `@kind_to_domain`), so a token with
`app:agent_memory:write` is creatable from Settings. The generic `/api/entries` keeps
working for reading; writes go through the routes below.

### `GET /api/agent_memory`

Query: `project` (optional), `tool` (optional), `include=body` (optional).
Returns `{data: [{path, project, tool, sha256, size, updated_at, body?}]}` sorted by
path. With `project=x`, global files (`project == ""`) are included too, so one call
returns everything a session in that repo needs. `size` is the byte length of `body`.

### `POST /api/agent_memory`

Body `{files: [{path, body}]}`. Upserts by path: creates when missing, replaces `body`
(and recomputes `sha256`, `project`, `tool`, `title`) when present; unchanged bodies are
not rewritten (`updated_at` stays). Returns the manifest (same shape as GET without
bodies) of the files sent. Any invalid path fails the whole request with 422 and
nothing is written. Last write wins; there is no server-side conflict detection.

### `DELETE /api/agent_memory?path=<path>`

Deletes the entry at that path (query parameter, so the OpenAPI validator sees a plain
string), 404 when absent, 204 on success.

All three broadcast the usual entry events through `Servant.Events` so the app updates
live. Routes are documented in OpenAPI like the other controllers.

## Skill

`docs/skills/servant-memory/SKILL.md`, versioned in this repo. Setup, once per machine:
copy the folder to `~/.claude/skills/` and `~/.cursor/skills-cursor/`, export
`SERVANT_URL` and `SERVANT_TOKEN` (token scope `app:agent_memory:write`).

What the skill tells the agent:

1. **Session start (pull)**: `project=$(basename "$PWD")`, `tool` = the current agent.
   `GET /api/agent_memory?project=$project&tool=$tool&include=body`. For each remote
   file, resolve the local path (`memory/<project>/…` → the agent's memory dir for this
   project, `skills/<tool>/…` → the tool's skills dir, `rules/<project>/…` →
   `.cursor/rules/`). Compare `sha256` with the local file: identical → nothing; local
   missing or remote `updated_at` newer than local mtime → write local; local newer →
   push. Both changed since they last matched cannot be detected without state, so when
   `sha256` differs and both look recent, the agent merges by hand (it is markdown) and
   pushes the merge.
2. **After every write** to a memory file, a skill or a rule: push that file at once with
   a one-element `POST`.
3. Never push files outside the three trees; never store secrets in memory files.

The skill ships the two `curl` invocations verbatim (with `jq` for the manifest loop) so
the agent does not improvise the protocol.

## Frontend

Built-in app `agent_memory` ("Agent memory", icon `Brain`), not in
`DEFAULT_ENABLED_APPS`. One file `apps/agent_memory/AgentMemoryApp.vue` plus the
three-line `index.ts`.

- Left: a tree built from `path` on the client (`Memory > project > file`,
  `Skills > tool > skill > file`, `Rules > project > file`), current file highlighted,
  search field focused on mount (filters on path).
- Right: the markdown rendered with the existing `apps/notes/render.ts`; an Edit button
  swaps in a textarea, Save calls `POST /api/agent_memory` through `ctx.api.fetch` (so
  the UI and the agents share the same write path), Cancel discards. Delete goes through
  `ctx.confirm.ask` then `DELETE`.
- No wikilinks, tags, favorites, attachments or folders management: that is what makes
  Notes 2000 lines and agents do not need it. Creating a file from the UI is out of
  scope (agents create files; the UI edits and deletes).

## Testing

- `Servant.AgentMemory` tests: derivation of project/tool/title from each path shape,
  invalid paths rejected (bad prefix, `..`, bad segment, missing segments), upsert is
  idempotent and keeps `updated_at` when the body is unchanged, `sha256` correct.
- Controller tests: 403 without `app:agent_memory:write`, 200 with it, batch upsert
  returns the manifest, `project` filter includes global files, `include=body`, delete
  404/204.
- Frontend: one test on the tree builder (paths in, nested structure out).
- The skill is exercised by hand: a session on the desktop pushes, one on the laptop
  pulls.

## Out of scope

WebDAV `/dav/agent_memory` (add if rclone sync is ever wanted), file history/versions,
server-side conflict detection, creating files from the UI, parsing frontmatter.
