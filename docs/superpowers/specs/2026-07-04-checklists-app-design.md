# Checklists app: design

**Approved:** 2026-07-04 (interactively, in-session)

## Goal

A "Checklists" mini-app on the same model as the other frontend apps: todo lists
organised by folder, with recurring lists that expose a **Reset** button
(unchecks every item).

## Approach

Frontend only, zero backend changes. Each checklist is a generic entry:

```json
{
  "kind": "checklist",
  "source": "manual",
  "title": "<list name>",
  "data": {
    "folder": "Perso",
    "recurring": true,
    "items": [{ "text": "Passeport", "done": false }]
  }
}
```

- Folders are a plain string on the checklist (single level, like Notes'
  `data.folder`); the sidebar groups by distinct value. Empty = shown at root.
- The generic entries API (`ctx.api.entries`) already provides user-scoped
  CRUD + `kind` filtering + PubSub broadcasts. No new endpoint.
- **Reset** is only rendered when `recurring` is true; it sets every item's
  `done` to `false` and saves.

## Components

- `frontend/src/apps/checklists/index.ts`: thin Vue adapter (same as Contacts).
- `frontend/src/apps/checklists/ChecklistsApp.vue`: sidebar (search, folder
  groups, list rows with done/total count) + main pane (title, folder,
  recurring toggle, items with inline edit/delete, add-item input, Reset,
  delete). Text edits debounced 600 ms; structural edits save immediately;
  saves serialized on a promise chain (same pattern as Notes).
- Registered in `registry.ts` (icon `ListChecks`) + icon map in `App.vue` +
  `checklist` entry in `KIND_CONFIG` (types.ts) for the data browser.
- `ChecklistsApp.test.ts`: load/toggle/reset coverage (vitest).

## Rejected alternative

Dedicated backend context + `/api/checklists` (like Notes): no server-side
logic exists to justify it; reset is a plain JSON update. YAGNI.

## Follow-ups (same day)

- Folder reorganisation: native HTML5 drag & drop; drag a list row onto a
  folder (or the tree background for root) to change its `data.folder`.
- Folder rename: pencil button on the folder row; renames `data.folder` on
  every list in the folder (rename to an existing name = merge).
- Display fix: the global stylesheet gives every `input` `width: 100%` +
  heavy padding, which stretched item checkboxes full-width; neutralised in
  scoped CSS (same trick as `.toggle input` in `style.css`).

- Custom folder ordering (Checklists **and** Notes): folders are derived
  strings, so the order is persisted in one `folder_order` entry per app
  (`title` = app id, `data.folders` = ordered paths) via the shared
  `apps/folderOrder.ts` helper. Drag a folder onto a sibling folder to insert
  it before, or onto the tree background to send it to the end. Unordered
  folders sort alphabetically after ordered ones; comparisons only ever happen
  between siblings, so one flat path list also works for Notes' nested tree.
- The same principles were applied to Notes: folder rename (pencil, renames
  children and syncs wikilinks server-side), drag & drop of notes between
  folders, and persisted folder ordering.

## Out of scope (add if ever needed)

Nested folders in Checklists, item reordering, due dates, scheduled
auto-reset, re-parenting folders by drag in Notes.
