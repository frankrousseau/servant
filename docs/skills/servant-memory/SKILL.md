---
name: servant-memory
description: Use at the start of every session and after writing any memory file, skill or Cursor rule. Pulls the agent memory and skills of the current repo from Servant and pushes local changes back, so the desktop and the laptop share one memory.
---

# Servant memory sync

Your memory (`~/.claude/projects/<cwd>/memory/*.md`), your skills
(`~/.claude/skills/*`, `~/.cursor/skills-cursor/*`) and the repo's Cursor rules
(`.cursor/rules/*.mdc`) live in Servant's Agent memory app, keyed by path:

| remote path | local file |
|-------------|------------|
| `memory/<project>/<file>.md` | `~/.claude/projects/<mangled cwd>/memory/<file>.md` |
| `skills/claude/<name>/…` | `~/.claude/skills/<name>/…` |
| `skills/cursor/<name>/…` | `~/.cursor/skills-cursor/<name>/…` |
| `skills/shared/<name>/…` | the current tool's skills dir |
| `rules/<project>/<file>.mdc` | `<repo>/.cursor/rules/<file>.mdc` |

`<project>` is `basename "$PWD"`, so run the scripts from the repo root.

## Setup (once per machine)

1. In Servant, Settings > API tokens: create a token with the `Agent memory: write` scope.
2. Export `SERVANT_URL` (e.g. `https://servant.example.com`) and `SERVANT_TOKEN` (the `srv_` token) in the shell profile.
3. Copy this folder to `~/.claude/skills/servant-memory/` and `~/.cursor/skills-cursor/servant-memory/`.
4. Seed once from each repo: `scripts/push.sh claude ~/.claude/projects/$(pwd | tr / -)/memory/*.md ~/.claude/skills/*/SKILL.md`.

## Session start: pull

Run, from the repo root, with `claude` or `cursor` depending on who you are:

```bash
~/.claude/skills/servant-memory/scripts/pull.sh claude
```

It writes every remote file that is missing locally or newer than the local copy
and prints `LOCAL NEWER <path>` for files you changed here since the last push.
For those, push them (below), or when the remote copy also changed, read both,
merge by hand (they are markdown), write the merge locally and push it.

## After every write: push

Right after saving a memory file, a skill file or a Cursor rule:

```bash
~/.claude/skills/servant-memory/scripts/push.sh claude <the file you wrote>
```

Several files can be pushed in one call. Do this in the same turn as the write,
not at the end of the session.

## Rules

- Never push a file outside the three trees, the server rejects other paths anyway.
- Never write secrets (tokens, passwords, keys) in a memory file: it is stored server side and readable in the app.
- Deleting is done from the app, not from here; a file deleted locally is simply not pulled back until someone deletes it remotely too.
- If `SERVANT_URL` or `SERVANT_TOKEN` is unset, say so once and carry on without syncing.
