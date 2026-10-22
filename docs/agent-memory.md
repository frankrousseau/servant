# Agent memory

The Agent memory app stores the memory files, skills and Cursor rules of your coding agents
(Claude Code, Cursor). Each machine sends its files to Servant and gets the files of the other
machines, so all machines share one memory. The files are plain markdown, and you can edit
them in the app.

The agents do the sync with a skill and an API token. Servant does not access your
filesystem, and there is no scheduled task.

## What is stored

There is one entry (`kind: "agent_memory"`) for each file. A path identifies the file:

| Path | Local file | Tool |
|------|------------|------|
| `memory/<project>/<file>.md` | `~/.claude/projects/<mangled cwd>/memory/<file>.md` (also `MEMORY.md`) | claude |
| `skills/claude/<name>/…` | `~/.claude/skills/<name>/…` | claude |
| `skills/cursor/<name>/…` | `~/.cursor/skills-cursor/<name>/…` | cursor |
| `skills/shared/<name>/…` | the skills directory of the current tool | shared |
| `rules/<project>/<file>.mdc` | `<repo>/.cursor/rules/<file>.mdc` | cursor |

- `<project>` is the name of the root folder of the repo (`servant-elixir`). If you clone the
  same repo at different paths on two machines, it uses the same files.
- `<mangled cwd>` is the Claude Code name of the project directory: the absolute path, with
  `-` in place of each `/`.

The server accepts only paths with these three prefixes, with segments in `[A-Za-z0-9._-]`
and no `..`. Each file has a `sha256` of its body, so the sync finds changed files without a
download.

## Setup (one time for each machine)

1. In Servant, open **Settings > API tokens**. Make a token with the **Agent memory: write**
   scope. Use one token for each machine: then you can revoke the token of a lost laptop
   only.
2. Add the two variables to your shell profile (`~/.zshrc`, `~/.bashrc`):

   ```bash
   export SERVANT_URL=https://servant.example.com
   export SERVANT_TOKEN=srv_...
   ```

3. Copy the skill from this repo into the skills directory of each tool:

   ```bash
   cp -r docs/skills/servant-memory ~/.claude/skills/servant-memory
   cp -r docs/skills/servant-memory ~/.cursor/skills-cursor/servant-memory
   ```

4. Send the initial files one time, from each repo that you want to share:

   ```bash
   ~/.claude/skills/servant-memory/scripts/push.sh claude \
     ~/.claude/projects/$(pwd | tr / -)/memory/*.md ~/.claude/skills/*/SKILL.md
   ```

5. To see the files, enable the app in **Settings > Apps > Agent memory**.

The scripts need `curl`, `jq`, GNU `date`, `sha256sum` and `realpath`. They work on Linux, not
on macOS. They verify the TLS certificate of the server, so the instance must serve its full
certificate chain.

## How a session syncs

The skill tells the agent to do these steps:

- **Pull when the session starts**: run `pull.sh claude` (or `cursor`) from the repo root. The
  script gets all the files of this project and the global skills of the tool. For each file:

  | Local copy | Result |
  |------------|--------|
  | Same hash | No change. |
  | Missing or older | The script writes the remote file. |
  | Newer than the remote file | The script does not change it and shows `LOCAL NEWER`. Push it, or merge it manually. |
  | Exists and the pull replaces it | The script keeps the previous content as `<file>.local` and shows `MERGE`. Compare the two files, keep the necessary content, delete the `.local` file and push. |

- **Push after each write**: run `push.sh claude <file>` immediately after the agent saves a
  memory file, a skill or a rule, in the same turn. You can push more than one file at a time.

On the server, the last write wins. There is no versioning.

**Servant controls, the agents apply.**

- **Delete** in the app is a soft delete. The file stays, with the `deleted` mark, in grey in
  the tree. At its next pull, each machine deletes its copy (`DELETED <path>`). The server
  refuses an agent push to this path until you click **Restore**. When all the machines have
  synced, click **Purge** to remove the file permanently.
- **Edit** in the app gives the file the `modified` mark. At the next pull, the Servant version
  replaces the local copy, also if the local copy is newer (`SERVANT EDIT <path>`). The
  previous copy stays as `.local`. The mark stays until an agent writes the file again.
- Only the agents make new files.

## API

All routes need the `app:agent_memory:read` scope (GET) or the `:write` scope (POST, DELETE),
or a session cookie. `/api/docs` documents them.

| Route | Purpose |
|-------|---------|
| `GET /api/agent_memory?project=<name>&tool=<claude\|cursor>&include=body` | Manifest sorted by path (`path`, `project`, `tool`, `sha256`, `size`, `updated_at`, and `body` on request). With `project`, it also returns the global files. With `tool`, it also returns the shared files. |
| `POST /api/agent_memory` with `{"files": [{"path": "...", "body": "..."}]}` | Upsert by path. An unchanged body causes no write. One invalid path rejects the full batch (422). A path deleted in the app gives 409. `"origin": "app"` gives the files the `modified` mark (or restores a deleted file). |
| `DELETE /api/agent_memory?path=<path>` | Soft delete (`deleted` mark), 404 if the path does not exist. `&purge=true` removes the row. |

The generic `/api/entries` route can read these entries but cannot write them. Thus no client
can bypass the path validation.

## Trust model

> **WARNING:** A client that can write agent memory on the server can add a skill file. The
> agent of each other machine then reads and follows this skill.

- Give the token only the `app:agent_memory:write` scope.
- Do not put secrets in memory files. The server stores them, and the app shows them.
- If you lose a machine, revoke its token in Settings.

The pull script refuses paths outside the three trees. It never replaces its own scripts.
