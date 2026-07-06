# Apps

Pluggable mini-applications (photos, contacts, files, calendar, notes) that
render into a host element and talk to the backend through a small, stable
contract. The full types live in [`types.ts`](./types.ts).

## Adding an app

1. Create `apps/<id>/index.ts` exporting a default `AppModule`:

   ```ts
   import type { AppModule } from '../types'

   const app: AppModule = {
     mount(el, ctx) {
       // render into `el`, use `ctx` to talk to the backend
     },
     unmount(el) {
       // optional: remove listeners/timers you added
     }
   }

   export default app
   ```

2. Register it in [`registry.ts`](../apps/registry.ts) with an `AppDef`
   (`id`, `name`, `icon`, `builtin`, and a lazy `load: () => import("./<id>")`).

## The `AppContext`

Passed to `mount`. It is the **only** supported way for an app to reach the rest
of the system; don't import stores/router directly.

- `navigate(path)`: router navigation.
- `confirm.ask({ message, ... })`: themed confirm dialog, resolves to a boolean.
- `viewer.open(items, startIndex)` / `.close()` / `.onDelete(cb)`: full-screen media viewer.
- `api.entries`: user-scoped CRUD (`list` / `get` / `create` / `update` / `delete` / `stats`).
- `api.upload(file, app?)`: upload a file, returns `{ path, filename, size, mime_type }`.
- `api.fetch(path, opts?)`: authenticated `fetch` for anything not covered above.

## Conventions

- Escape any user data before inserting it into HTML; use the shared
  [`escapeHtml`](./escapeHtml.ts), never a per-app copy.
- Clean up every listener/timer in `unmount` (and on modal close) to avoid leaks.
- Files load via `<img src="/files/…">`; the backend authenticates them with an
  HttpOnly cookie, so no token handling is needed in the app.
