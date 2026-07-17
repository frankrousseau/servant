# Custom apps (installed from git)

Servant can install extra apps from a git repository, per user, from Settings > Apps.
Installed apps appear in the sidebar and load exactly like the built-in ones.

## Repository convention

The repository must contain, at its root, a `servant-app.json` manifest:

```json
{
  "id": "todo-plus",
  "name": "Todo Plus",
  "description": "A fancier todo app",
  "icon": "ListChecks",
  "entry": "dist/index.js"
}
```

- `id` (required): lowercase alphanumeric with dashes/underscores, max 40 chars.
  Must not collide with built-in app ids or SPA routes.
- `name` (required): display name, max 60 chars.
- `entry` (required): repo-relative path to a **pre-built, self-contained ES
  module** (`.js` or `.mjs`). No build runs on the server (production has no
  node), so the built file must be committed.
- `icon` (optional): a lucide icon name already bundled by the SPA; unknown
  or missing icons fall back to Puzzle.
- `description` (optional).

## Entry module contract

The entry module default-exports an `AppModule` (see `frontend/src/apps/types.ts`):

```js
export default {
  mount(el, ctx) {
    // el: the host element; ctx: navigate, confirm, viewer, api (entries CRUD,
    // aggregate, upload, fetch). Same context as built-in apps.
    el.innerHTML = '<h1>Hello</h1>'
  },
  unmount(el) {}
}
```

The module must be self-contained: bare imports (`import ... from 'vue'`) will
not resolve. Bundle any framework you use, or stick to plain DOM.

## How it works

- Install clones the https repo (shallow), validates the manifest, and copies
  the tree to `FILES_DIR/{user_id}/installed_apps/{app_id}/` (the `.git`
  directory is dropped). Requires `git` on the server.
- The SPA imports the entry module from
  `/files/{user_id}/installed_apps/{app_id}/{entry}`, authenticated by the
  session cookie like any file.
- Installed apps run in the SPA with the user's full session privileges;
  install only trusted repositories.
- Uninstalling (Settings > Apps) removes the files and the sidebar entry.
- Updating (Settings > Apps, refresh button) re-clones the stored repo URL,
  re-validates the manifest (the id must not change) and replaces the files.

## Generated apps (builder agent)

When agents are enabled (Settings > Agents, off by default), Servant can also
write an app for you: the Agents section (Builder tab) > "Generate an app" sends your
description to the model server you configured (any OpenAI-compatible
endpoint; a local Ollama by default) and installs the produced module through
the same rail as git apps: same manifest validation, same /files serving,
same session privileges.

- Generated apps have no repository. They can be modified (a new instruction
  rewrites the module; the previous version is kept as `index.prev.js`) and
  restored (swap back to that previous version) from the Agents section (Builder tab).
- The model only receives your app name, your description and, on modify,
  the app's current source: never your personal data.
- Every run is recorded with its model, token usage and duration in
  the Agents section.
- Generated code can be incorrect: review an app before trusting it with
  your data.
