# Custom apps

**Missing an app? Install one from git, or describe it and let Servant write it.**

A custom app sits in the sidebar like a built-in one, with the same data and the same look. Pin
it, unpin it or move it on the **Apps** page (`/apps`).

> [!WARNING]
> **An app has the full rights of your session:** it can read and change all your data.
> Install only repositories that you trust, and read generated code before you rely on it.

## Install, update, uninstall

In **Settings > Apps**:

- **Install:** paste an `https://` git URL. Servant clones it, checks the manifest and copies
  the files (the server needs `git`).
- **Update:** the refresh button clones again and replaces the files. The `id` must not change.
- **Uninstall:** removes the files and the sidebar entry.

## Let Servant write it

Turn agents on (**Settings > Agents**), then click **Generate an app** in **Agents > Builder**
and describe what you want. Your model server (OpenAI-compatible, a local Ollama by default)
writes the module, and Servant installs it like a git app.

- **Modify** it with a new instruction; **Restore** brings the previous version back
  (`index.prev.js`).
- The model sees the app name, your description and, to modify, the current source. **Never
  your data.**
- The Agents section logs each run with its model, tokens and duration.

## Build your own

### The manifest

`servant-app.json`, at the root of the repository:

```json
{
  "id": "todo-plus",
  "name": "Todo Plus",
  "description": "A fancier todo app",
  "icon": "ListChecks",
  "entry": "dist/index.js"
}
```

| Field | Required | Rule |
|-------|:--------:|------|
| `id` | ✅ | Lowercase letters, digits, `-` and `_`, 40 characters max, unlike any built-in app id or SPA route. |
| `name` | ✅ | Display name, 60 characters max. |
| `entry` | ✅ | A **pre-built, self-contained ES module** (`.js` or `.mjs`), relative to the repo root. Production has no Node.js: commit the built file. |
| `icon` | | Name of a Lucide icon in the SPA bundle (default: Puzzle). |
| `description` | | Free text. |

### The entry module

Export an `AppModule` as default (types in `frontend/src/apps/types.ts`):

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

Bare imports (`import ... from 'vue'`) do not resolve: bundle your framework, or use plain DOM.

### Under the hood

Servant copies the files (without `.git`) to `FILES_DIR/{user_id}/installed_apps/{app_id}/`,
generated apps included. The SPA imports the entry from
`/files/{user_id}/installed_apps/{app_id}/{entry}`, with your session cookie as for any file.
