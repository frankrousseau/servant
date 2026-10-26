# Coding guidelines

The rules every change to Servant follows, whether a person or a coding agent writes it. For
the setup, the project structure and the architecture, see [development.md](development.md).

Servant is an **API-only** Phoenix backend (`--no-html --no-live --no-assets`) paired with a
Vue 3 SPA in `frontend/`. There is no LiveView, no server-rendered HTML and no
`core_components.ex`, so the standard Phoenix HTML and LiveView guidelines do **not** apply.
The web layer is JSON controllers and Phoenix Channels.

- [General](#general)
- [Frontend](#frontend): [tooling](#tooling), [Vue style](#vue-style),
  [shared widgets](#shared-widgets), [code organization](#code-organization),
  [TypeScript](#typescript), [data and state](#data-and-state),
  [icons and copy](#icons-and-copy), [accessibility](#accessibility), [tests](#frontend-tests)
- [Backend](#backend): [Elixir style](#elixir-style), [Elixir and OTP](#elixir-and-otp),
  [Phoenix](#phoenix), [Ecto](#ecto), [tests](#backend-tests), [Mix](#mix)

## General

- **Run `mix precommit` before you commit** and fix what it reports. It compiles with
  warnings as errors, audits the dependencies, formats the Elixir code, and runs the backend
  tests, the frontend tests and the frontend build. It does not run Prettier: see
  [tooling](#tooling).
- **Never write em dashes (—)** anywhere: comments, doc strings, UI copy, docs, commit
  messages. Use a comma, colon, semicolon, parentheses, or a plain hyphen instead.
  Entry-title separators and empty-cell placeholders use a plain "-" ("Name - org - email").
  The only em dashes left in the code are the legacy-separator (" — ") parsing fallbacks that
  keep pre-July-2026 entries readable; never remove those.
- **Commit messages are short.** The title is `area: what changed` in 50 characters or fewer
  (`calendar: labels on one baseline`). Add a body only when the title is not enough: 2 to 4
  lines on why, and on what the diff does not show. Never list the changes file by file, and
  never repeat the title.

## Frontend

The SPA is Vue 3 and TypeScript on Vite, with vue-router, Pinia, `@vueuse/core` and Vitest.
The [project structure](development.md#project-structure) maps `frontend/src/`.

### Tooling

- Run from `frontend/`: `npm run dev` (Vite dev server), `npm run test` (Vitest),
  `npm run format` (Prettier), `npm run build` (`vue-tsc -b`, then `vite build`).
- `mix precommit` runs the frontend tests and the build, so a type error fails it. It does
  not run Prettier: run `npm run format` before you commit frontend changes (config in
  `frontend/.prettierrc.json`: no semicolons, single quotes, no trailing commas,
  `arrowParens: avoid`).
- There is no ESLint. The strict type check (`tsconfig.app.json`: `strict`,
  `noUnusedLocals`, `noUnusedParameters`) and Prettier are the only gates.

### Vue style

All Vue code follows the [official Vue.js style guide](https://fr.vuejs.org/style-guide/),
applied by priority:

- **Priority A (essential, always)**: multi-word component names; typed prop definitions
  (`defineProps<{...}>()`); every `v-for` carries a `:key`; never `v-if` and `v-for` on the
  same element (filter in a computed instead); component styles are `scoped` (a global block
  needs a comment justifying it).
- **Priority B (strongly recommended)**: one component per file, PascalCase filenames and
  template tags, self-closing tags for empty components, camelCase prop declarations, complex
  template expressions extracted into computeds, consistent directive shorthands (`:`, `@`,
  `#`).
- **Priority C (recommended)**: SFC top-level order is `<script>` then `<template>` then
  `<style>` in every file.

### Shared widgets

Reach for the shared components in `frontend/src/components/` before native controls or
ad-hoc markup:

| Need | Widget |
|------|--------|
| Closed single choice (never a bare `<select>` or a `<datalist>` picker) | `ComboBox` |
| Free text with suggestions | `AutocompleteInput` |
| Confirmation | `ConfirmModal` through `useConfirm` |
| Any other modal | `ServantDialog` |
| Section tabs and view switches | `TabBar` |
| Search and filter boxes | `SearchField` |
| Loading, error and empty states of a list | `LoadState` |
| Dates | `DateInput` |
| Entry kind icon | `KindIcon` |
| Media | `MediaViewer`, `VideoPlayer` |

Fall back to a native control only when no shared widget covers the need.

### Code organization

- **Import order** in `<script setup>`: framework (`vue`, `vue-router`), then components,
  then app modules sorted by path (`api/`, `apps/`, `composables/`, `connectors`, `lib/`,
  `stores/`), then `import type` lines last; one import per module, names sorted inside each
  brace.
- **Scoped styles follow the template**: layout rules first, then one commented block per
  template region in display order (`/* ----- Connectors ----- */`). A modifier class
  (`.thing--variant`) is declared after its base so it wins the cascade at equal
  specificity.
- **Shared helpers live in `frontend/src/lib/`** (dates and civil-date strings in
  `lib/datetime.ts`, per-kind routes in `lib/entryRoute.ts`). Before you write a helper in a
  view or an app, check `lib/` and the owning app module, and promote duplicated logic there
  instead of copying it.
- **Design tokens over literals**: `var(--font-mono)`, `var(--font-display)`, theme colors
  (`--primary`, `--danger`, ...), never a hardcoded font stack or palette hex in a component.
  Font sizes come from the type scale (`--text-sm` to `--text-2xl`); `--text-sm` (0.875rem)
  is the floor, nothing is set smaller. Floating panels (menus, popovers, tips) sit on
  `--bg-raised` under `--shadow-raised`; form control edges use `--border-strong`, dividers
  and card edges `--border`.
- **Name bindings with words**: no single-letter variables (`entry`, `list`, `connector`,
  never `e`, `l`, `c`), in arrow functions and `v-for` included. The accepted exceptions are a
  numeric loop index `i` and the `(a, b)` pair of a sort comparator.
- **Derive in computeds, not in the template**: anything involving a loop, `Date`/`Intl`
  work, or a lookup per row goes through a `computed` (or is attached to the items of an
  existing one), so it is cached instead of recomputed on every render.

### TypeScript

- Every SFC is `<script setup lang="ts">`. Props and emits use the type-based macros
  (`defineProps<{...}>()`, `defineEmits<{...}>()`).
- **No `any`.** A caught error stays `unknown` and is read with
  `err instanceof Error ? err.message : '<fallback>'` (`messageOf` in `lib/reportError.ts` is
  for error reports, not UI copy). Narrow an unknown payload with a check, not a cast.
- **API shapes live in `src/types.ts`.** It mirrors what the Phoenix controllers render and
  holds types only, so importing a shape never pulls runtime code. A type used by one module
  stays in that module and is exported from it (`LoadStatus` in `LoadState.vue`).

### Data and state

- **One HTTP client.** Every `/api` call goes through `composables/apiClient.ts` (`apiFetch`,
  `apiJson`): it adds the Bearer header, logs out on a 401 and turns an error payload into a
  readable message. Views call the named functions of `api/*.ts` (add one there rather than
  spelling a path and its envelope in a view), or `useApi` for a one-off call. A raw `fetch`
  is only for what the client cannot do: the `/api/auth` calls made before a token exists,
  and the `/files/...` binaries, which the HttpOnly cookie authenticates.
- **Apps reach the system through `ctx` only.** Code under `apps/<id>/` imports `lib/` and
  the shared components, never a store, the router, `api/` or `apiClient`. It uses the
  `AppContext` it receives ([`frontend/src/apps/README.md`](../frontend/src/apps/README.md));
  a missing capability is added to the context in `apps/createContext.ts`. App preferences
  go through `ctx.preferences` with `<app>.<name>` keys.
- **Pinia holds only the state several views share** (`stores/auth`, `stores/apps`). State
  that one view or app owns stays in its component or in a composable.
- **Live updates.** Subscribe with `useSocket` in a view or `ctx.events` in an app
  (`onEntryChange`, `onBulkChange`), and call the returned unsubscribe in `onUnmounted`. A
  deleted entry arrives with its `id` only. A sync or an import sends one `onBulkChange`
  instead of per-entry events, so an app that shows synced data refetches there. Coalesce
  bursts of entry events before refetching.

### Icons and copy

- **Icons are Lucide** (`lucide-vue-next`), never a Unicode character or an emoji standing in
  for one. An app declares its icon by name and `lib/appIcons.ts` maps the name to the
  component. An icon-only button carries an `aria-label`.
- **The UI says "Sources"** for connectors ("Add a Source"), never "Connectors" or
  "Integrations". Code, routes and the API keep `connector`.

### Accessibility

- **Modals are native `<dialog>` elements** opened with `showModal()`: the browser then
  provides the focus trap, Escape handling and focus restoration for free. `ServantDialog`
  does all of this (title wired to `aria-labelledby`, labelled icon close button plus a text
  one); put `autofocus` on the primary action. A hand-written `<dialog>` (fullscreen viewer,
  command palette) follows the same rules. Never rebuild a modal out of an overlay `<div>`.
- **The active nav link is `[aria-current="page"]`**: vue-router already sets that attribute
  on the exact-active `RouterLink`, so style the attribute selector rather than
  `.router-link-active`. The state announced to assistive tech and the state shown on screen
  then cannot diverge.
- **Every informative image gets a real, descriptive `alt`** (a photo uses its entry title, a
  chart says what it shows: "Crypto portfolio value over six months"; never a filename or
  "image"). Purely decorative images get `alt=""`, and commentary longer than a description
  belongs in a `<figcaption>`, not in the alt.
- **Default focus lands on the search field** when the page has one (`autofocus`, or a focus
  on mount when the field renders asynchronously); without a search field, it lands on a
  navigation button. A page never opens with the focus stranded on `<body>`.
- **Keyboard and zoom fundamentals**: `lang` on `<html>` and `hreflang` on links to content
  in another language; the viewport meta never disables zoom; every interactive element keeps
  a visible `:focus-visible` style (the global outline in `style.css` counts, do not
  `outline: none` it away without a replacement); non-essential animations are disabled under
  `@media (prefers-reduced-motion: reduce)`.

### Frontend tests

- Tests sit next to the code as `<name>.test.ts` (Vitest, jsdom, `@vue/test-utils`). Pure
  helpers in `lib/` and in app modules get unit tests, shared components get mount tests.
- `src/test-setup.ts` already renders `Teleport` content in place, registers the global
  directives (`v-autofocus`, `v-click-key`) and polyfills `<dialog>`. Register a new global
  directive there too, not in each test file.

## Backend

### Elixir style

All Elixir code follows [The Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide).
`mix format` covers layout; these are the rules it does **not** enforce:

- `@moduledoc` comes immediately after `defmodule` (use `@moduledoc false` when there is
  nothing to say), then directives in this order: `@behaviour`, `use`, `import`, `require`,
  `alias` (alphabetical), module attributes, `defstruct`, `@type`, callbacks and functions.
- Reference the current module with `__MODULE__`.
- No single-pipe expressions (`foo |> bar()` becomes `bar(foo)`); pipelines start from a bare
  value, not a function call.
- Prefer `if` over `unless` when there is an `else`; use `true ->` (never `:else ->`) as the
  final `cond` clause.
- Functions returning booleans end in `?` and do not start with `is_`: the `is_` prefix is
  reserved for guards.
- `@spec` sits right under `@doc`, before the function head; a module's main type is named
  `t`.
- `defstruct` omits the square brackets; keyword lists use `[a: 1]`, never `[{:a, 1}]`.
- Exception modules end in `Error`, with lowercase unpunctuated messages.
- Comment annotations are uppercase with a colon (`# TODO:`), placed on the line above the
  code they describe.

### Elixir and OTP

- **HTTP goes through `Req`** (already a dependency; `Servant.HTTP` holds the defaults and
  the SSRF guard for connector fetches). Never add `:httpoison`, `:tesla` or `:httpc`.
- **No new dependency unless it is agreed first.** The standard library covers dates and
  times (`Time`, `Date`, `DateTime`, `Calendar`); the one exception is `date_time_parser`
  for parsing.
- Lists have no index access through the Access syntax (`list[i]` is invalid): use
  `Enum.at/2`, pattern matching or `List`.
- Variables are immutable but can be rebound. A block expression (`if`, `case`, `cond`)
  cannot rebind a variable for the code after it, so bind its result instead:

  ```elixir
  socket =
    if connected?(socket) do
      assign(socket, :val, val)
    end
  ```

- One module per file: nested modules in the same file cause cyclic dependencies and
  compilation errors.
- Structs do not implement Access: read `my_struct.field`, never `my_struct[:field]`, and use
  `Ecto.Changeset.get_field/2` on a changeset.
- Never call `String.to_atom/1` on user input (atoms are never garbage collected).
- OTP primitives like `DynamicSupervisor` and `Registry` take a name in the child spec
  (`{DynamicSupervisor, name: MyApp.MyDynamicSup}`), then you call them by that name
  (`DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`).
- For concurrent enumeration with back-pressure, use
  `Task.async_stream(collection, callback, options)`, most of the time with
  `timeout: :infinity`.

### Phoenix

- A router `scope` block prefixes its alias to every route inside it, so never repeat the
  prefix and never add an `alias` for a route: in `scope "/admin", AppWeb.Admin`, the module
  `UserController` resolves to `AppWeb.Admin.UserController`.
- `Phoenix.View` is gone from Phoenix; do not use it.

### Ecto

- Preload the associations that the rendering reads, in the query itself.
- `Ecto.Schema` fields use the `:string` type, `:text` columns included
  (`field :name, :string`).
- Read changeset fields with `Ecto.Changeset.get_field(changeset, :field)`.
- `Ecto.Changeset.validate_number/2` has no `:allow_nil` option, and needs none: validations
  run only when a change for the field exists and is not nil.
- Fields set programmatically, such as `user_id`, are never listed in `cast`; set them
  explicitly when you build the struct.
- Generate migrations with `mix ecto.gen.migration migration_name_using_underscores`, so the
  timestamp and the conventions are right. Remember `import Ecto.Query` in seed code and Mix
  tasks.

### Backend tests

- The actual value goes left of the operator, the expected value right
  (`assert actual == expected`).
- Start processes with `start_supervised!/1`: it guarantees the cleanup between tests.
- No `Process.sleep/1` and no `Process.alive?/1`. To wait for a process to finish, monitor it
  and assert on the DOWN message:

  ```elixir
  ref = Process.monitor(pid)
  assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  ```

  To make sure a process has handled the earlier messages before the next call, use
  `_ = :sys.get_state(pid)`.
- To debug failures, run one file (`mix test test/my_test.exs`) or the previous failures
  (`mix test --failed`).

### Mix

- Read a task's docs and options before you use it (`mix help task_name`).
- `mix deps.clean --all` is almost never needed; avoid it unless you have a good reason.
