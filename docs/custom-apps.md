# Custom apps (installed from git)

Each user can install more apps from a git repository, in Settings > Apps. An installed app
shows in the sidebar (each user can unpin it from there on the Apps page, `/apps`) and loads
like a built-in app.

## Repository convention

The root of the repository must contain a `servant-app.json` manifest:

```json
{
  "id": "todo-plus",
  "name": "Todo Plus",
  "description": "A fancier todo app",
  "icon": "ListChecks",
  "entry": "dist/index.js"
}
```

- `id` (required): lowercase letters, digits, dashes and underscores, 40 characters maximum.
  It must be different from the built-in app ids and the SPA routes.
- `name` (required): display name, 60 characters maximum.
- `entry` (required): path, from the repo root, to a **pre-built, self-contained ES module**
  (`.js` or `.mjs`). The server does not build the app (production has no Node.js), so commit
  the built file.
- `icon` (optional): the name of a Lucide icon in the SPA bundle. If the icon is unknown or
  missing, the app uses Puzzle.
- `description` (optional).

## Entry module contract

The entry module exports an `AppModule` as default (see `frontend/src/apps/types.ts`):

```js
export default {
  mount(el, ctx) {
    // el: the host element; ctx: navigate, confirm, viewer, preferences, api
    // (entries CRUD, aggregate, upload, fetch). Same context as built-in apps.
    el.innerHTML = '<h1>Hello</h1>'
  },
  unmount(el) {}
}
```

The module must be self-contained. Bare imports (`import ... from 'vue'`) do not resolve.
Bundle your framework, or use plain DOM.

## How it works

- **Install**: Servant clones the https repo (shallow) and validates the manifest. Then it
  copies the files, without `.git`, to `FILES_DIR/{user_id}/installed_apps/{app_id}/`. The
  server must have `git`.
- **Load**: the SPA imports the entry module from
  `/files/{user_id}/installed_apps/{app_id}/{entry}`. The session cookie gives access, as for
  all files.
- **Uninstall** (Settings > Apps): Servant removes the files and the sidebar item.
- **Update** (Settings > Apps, refresh button): Servant clones the stored repo URL again,
  validates the manifest and replaces the files. The id must not change.

> **WARNING:** An installed app runs in the SPA with all the privileges of the user session.
> Install only repositories that you trust.

## Generated apps (builder agent)

When agents are on (Settings > Agents, off by default), Servant can write an app for you. In
the Agents section, open the Builder tab and click "Generate an app". Servant sends your
description to your model server (an OpenAI-compatible endpoint, a local Ollama by default).
Then it installs the module as it installs a git app: same manifest validation, same /files
serving, same session privileges.

- A generated app has no repository. In the Builder tab, you can:
  - **modify** it: a new instruction writes the module again, and Servant keeps the previous
    version as `index.prev.js`;
  - **restore** it: Servant puts the previous version back.
- The model gets only the app name, your description and, for a modification, the current
  source of the app. It does not get your personal data.
- The Agents section shows each run with its model, token usage and duration.

> **CAUTION:** Generated code can be incorrect. Examine an app before you give it your data.
