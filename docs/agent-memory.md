# Agent memory

The Agent memory app stores what your coding agents (Claude Code, Cursor) learn and
carry around: their per-project memory files, their skills and the repo's Cursor rules.
Every machine you work from pushes its files to Servant and pulls the others' back, so
the desktop and the laptop share one memory. The files stay plain markdown, readable and
editable in the app like notes.

Servant never touches your filesystem: the agents themselves sync, through a skill and
an API token. Nothing runs on a schedule.

## What is stored

One entry (`kind: "agent_memory"`) per file, identified by a path:

| Path | Local file | Tool |
|------|------------|------|
| `memory/<project>/<file>.md` | `~/.claude/projects/<mangled cwd>/memory/<file>.md` (incl. `MEMORY.md`) | claude |
| `skills/claude/<name>/…` | `~/.claude/skills/<name>/…` | claude |
| `skills/cursor/<name>/…` | `~/.cursor/skills-cursor/<name>/…` | cursor |
| `skills/shared/<name>/…` | the current tool's skills directory | shared |
| `rules/<project>/<file>.mdc` | `<repo>/.cursor/rules/<file>.mdc` | cursor |

`<project>` is the name of the repo's root folder (`servant-elixir`), so the same repo
cloned under different paths on two machines maps to the same files. `<mangled cwd>` is
how Claude Code names its per-project directory: the absolute path with `/` replaced by
`-`.

Paths are validated server side (three prefixes, segments limited to
`[A-Za-z0-9._-]`, no `..`); anything else is rejected. Each file carries a `sha256` of its
body so the sync can tell "unchanged" from "changed" without downloading it.

## Setup, once per machine

1. In Servant, **Settings > API tokens**: create a token with the **Agent memory:
   write** scope. Use one token per machine, so a lost laptop can be revoked alone.
2. Export the two variables in your shell profile (`~/.zshrc`, `~/.bashrc`):

   ```bash
   export SERVANT_URL=https://servant.example.com
   export SERVANT_TOKEN=srv_...
   ```

3. Copy the skill from this repo into each tool's skills directory:

   ```bash
   cp -r docs/skills/servant-memory ~/.claude/skills/servant-memory
   cp -r docs/skills/servant-memory ~/.cursor/skills-cursor/servant-memory
   ```

4. Seed once, from each repo whose memory you want to share:

   ```bash
   ~/.claude/skills/servant-memory/scripts/push.sh claude \
     ~/.claude/projects/$(pwd | tr / -)/memory/*.md ~/.claude/skills/*/SKILL.md
   ```

5. Enable the app in **Settings > Apps > Agent memory** to browse what was pushed.

The scripts need `curl`, `jq`, GNU `date`, `sha256sum` and `realpath` (Linux; macOS is
not supported as is). They verify the server's TLS certificate, so the instance must serve
its full certificate chain.

## How a session syncs

The skill tells the agent to:

- **Pull at session start**: `pull.sh claude` (or `cursor`) from the repo root fetches
  every file of this project plus the tool's global skills. A file whose hash matches the
  local copy is skipped; a missing or older local copy is written; a local copy that is
  newer than the remote one is left alone and reported as `LOCAL NEWER` (push it, or
  merge by hand). When the pull overwrites a file that existed locally, the previous
  content is kept next to it as `<file>.local` and the line reads `MERGE`: compare, keep
  what matters, delete the `.local`, push.
- **Push after every write**: `push.sh claude <file>` right after the agent saves a
  memory file, a skill or a rule, in the same turn. Several files can be pushed at once.

Last write wins on the server; there is no versioning. The app shows each file's
`updated_at`, size and tool, renders the markdown, and lets you edit or delete a file.

**Servant curates, agents apply.** Deleting a file in the app is a soft delete: the file
stays, marked `deleted`, greyed out in the tree, and every machine removes its copy at its
next pull (`DELETED <path>`); an agent push to that path is refused until you **Restore**
it, and **Purge** removes it for good once every machine has synced. Editing a file in the
app marks it `modified`: at the next pull the Servant version replaces the local copy
whatever its date (`SERVANT EDIT <path>`, previous copy kept as `.local`), and the badge
stays until an agent rewrites the file.
Creating files is the agents' job.

## API

All routes need the `app:agent_memory:read` (GET) or `:write` (POST, DELETE) scope, or a
session cookie. They are documented in `/api/docs` with the rest.

| Route | Purpose |
|-------|---------|
| `GET /api/agent_memory?project=<name>&tool=<claude\|cursor>&include=body` | manifest sorted by path (`path`, `project`, `tool`, `sha256`, `size`, `updated_at`, `body` on demand); `project` also returns global files, `tool` also returns shared ones |
| `POST /api/agent_memory` with `{"files": [{"path": "...", "body": "..."}]}` | upsert by path; unchanged bodies are left alone; one invalid path rejects the batch (422); 409 on a path deleted in the app. `"origin": "app"` marks the files `modified` (or restores a deleted one) |
| `DELETE /api/agent_memory?path=<path>` | soft delete (marks `deleted`), 404 when absent; `&purge=true` removes the row |

The generic `/api/entries` can read these entries but refuses to write them, so the path
validation cannot be bypassed.

## Trust model

Anything that can write agent memory on the server can place a skill file that the other
machine's agent will read and follow. Keep the token scoped to `app:agent_memory:write`
only, never put secrets in memory files (they are stored server side and readable in the
app), and revoke a machine's token from Settings if the machine is lost. The pull script
refuses paths outside the three trees and never overwrites its own scripts.
