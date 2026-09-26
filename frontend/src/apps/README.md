# Apps

Pluggable mini-applications (calendar, checklists, contacts, files, finance,
notes, photos, trackers) that render into a host element and talk to the backend
through a small, stable contract. The full types live in [`types.ts`](./types.ts).

The contract is deliberately framework-free: an app is anything that can `mount`
into an element. Built-in apps happen to be Vue, apps installed from git (see
[`docs/custom-apps.md`](../../../docs/custom-apps.md)) can be plain DOM.

## Adding a built-in app

1. Write `apps/<id>/<Name>App.vue` as a normal SFC. It receives the context as a
   prop:

   ```ts
   defineProps<{ ctx: AppContext }>()
   ```

2. Add `apps/<id>/index.ts`, the three-line adapter that turns the component
   into an `AppModule`:

   ```ts
   import { defineVueApp } from '../defineVueApp'
   import MyApp from './MyApp.vue'

   export default defineVueApp(MyApp)
   ```

3. Register it in [`registry.ts`](./registry.ts) with an `AppDef` (`id`, `name`,
   `icon`, `builtin`, and a lazy `load: () => import('./<id>')`). The array is
   alphabetical by name and doubles as the sidebar order. New apps stay out of
   `DEFAULT_ENABLED_APPS` unless they should be on for every account; users turn
   them on in Settings > Apps.

An app that is not Vue skips `defineVueApp` and default-exports an `AppModule`
directly:

```ts
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

## The `AppContext`

Passed to `mount` (and forwarded as the `ctx` prop). It is the **only** supported
way for an app to reach the rest of the system; don't import stores/router
directly.

- `navigate(path)`: router navigation.
- `confirm.ask({ message, title?, confirmLabel?, danger? })`: themed confirm dialog, resolves to a boolean.
- `preferences.get(key, fallback)` / `.set(key, value)`: UI preferences stored on the account, so they follow the user across devices (hidden calendars, grouping, last open item). Namespace keys as `<app>.<name>`; `get` is reactive, `set` saves that one key (`null` removes it). `preferenceRef(ctx, key, fallback)` in `preference.ts` wraps one as a writable ref.
- `viewer.open(items, startIndex)` / `.close()` / `.onDelete(cb)` / `.onClose(cb)`: full-screen media viewer. `onClose` fires on user-initiated closes only (backdrop, Esc, Close button), so the app can sync its URL or state.
- `api.entries`: user-scoped CRUD (`list` / `get` / `create` / `update` / `delete` / `stats` / `aggregate`). `list` pages through the results transparently, `aggregate` returns server-side COUNT/SUM bucketed by local day/week/month/year.
- `api.upload(file, app?, onProgress?)`: upload a file, returns `{ path, filename, size, mime_type }`; `onProgress` receives a percentage.
- `events.onEntryChange(cb)`: live entry changes pushed over the data channel (a deleted entry carries only its `id`). Returns an unsubscribe to call in `unmount` (or `onUnmounted`); coalesce bursts before refetching.
- `api.fetch(path, opts?)`: authenticated `fetch` for anything not covered above (the Notes app uses it for `/api/notes`, which is the only way to write a note, the Photos app for media backfill).

## Conventions

- Reach for the shared widgets in [`../components/`](../components/) (`ComboBox`,
  `AutocompleteInput`, `DateInput`, `KindIcon`, `MediaViewer`, …) before writing
  a native control or ad-hoc markup.
- Vue templates escape interpolated data for you. When an app builds raw HTML
  anyway (`v-html`, markdown rendering), escape user data with the shared
  [`escapeHtml`](./escapeHtml.ts), never a per-app copy.
- Clean up every listener/timer in `unmount` (and on modal close) to avoid
  leaks; `defineVueApp` handles the Vue instance itself.
- Files load via `<img src="/files/…">`; the backend authenticates them with an
  HttpOnly cookie, so no token handling is needed in the app.
- Tests sit next to the component as `*.test.ts` and run with the rest of the
  suite (`npm test`).
