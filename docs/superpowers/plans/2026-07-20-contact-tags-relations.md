# Contact Tags and Relations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Free-form tags (chip filter bar + per-contact chips) and fixed-vocabulary reciprocal relations between contacts, stored in `contact.data`, frontend-only.

**Architecture:** A pure module `relations.ts` (types, inverses, tag normalization, relation list operations) consumed by `ContactsApp.vue`. Tags and relations save immediately via `ctx.api.entries.update` in view mode (like the birthday toggle); the edit form is untouched. Reciprocity = two sequential updates (current contact, then target with the inverse type). No backend change: entries are schemaless, and both sync paths preserve unknown `data` keys (CardDAV PUT merges; the vCard connector never updates existing entries).

**Tech Stack:** Vue 3 `<script setup>` + TypeScript, vitest, existing `ctx.api.entries` app context.

**Spec:** `docs/superpowers/specs/2026-07-20-contact-tags-relations-design.md`

## Global Constraints

- **Never write em dashes** anywhere (code, comments, UI copy, commits). Use "-" or rephrase.
- UI copy in English, sober (matches the rest of the app: "Add contact", "No contact info").
- Prettier before commit: `cd frontend && npx prettier --write <files>` (no semicolons, single quotes, no trailing commas, `arrowParens: avoid`).
- Vue style guide: typed `defineProps`, `:key` on every `v-for`, no `v-if` with `v-for` on the same element, scoped styles.
- Fixed relation vocabulary, exactly: `partner`, `parent`, `child`, `sibling`, `friend`, `colleague`. Only directional pair: `parent` <-> `child`.
- Tags normalized: trim, lowercase, deduplicated, empties dropped.
- The edit form (`mode !== 'view'`) is NOT modified by this plan.
- All verification commands run from `frontend/`.

---

### Task 1: Pure module `relations.ts` with tests

**Files:**
- Create: `frontend/src/apps/contacts/relations.ts`
- Test: `frontend/src/apps/contacts/relations.test.ts`

**Interfaces:**
- Consumes: `Entry` from `frontend/src/apps/types.ts` (fields used: `data: Record<string, unknown>`).
- Produces (used verbatim by Tasks 2 and 3):
  - `RELATION_TYPES: readonly ['partner', 'parent', 'child', 'sibling', 'friend', 'colleague']`
  - `type RelationType`, `interface Relation { contact_id: string; type: RelationType }`
  - `relationLabel(type: string): string` (capitalized, e.g. "Friend")
  - `inverseType(type: RelationType): RelationType`
  - `normalizeTags(raw: unknown): string[]`
  - `tagsOf(entry: Entry): string[]`
  - `relationsOf(entry: Entry): Relation[]`
  - `withRelation(relations: Relation[], contactId: string, type: RelationType): Relation[]`
  - `withoutRelation(relations: Relation[], contactId: string): Relation[]`

- [ ] **Step 1: Write the failing tests**

`frontend/src/apps/contacts/relations.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import {
  RELATION_TYPES,
  inverseType,
  relationLabel,
  normalizeTags,
  tagsOf,
  relationsOf,
  withRelation,
  withoutRelation
} from './relations'
import type { Entry } from '../types'

function entry(data: Record<string, unknown>): Entry {
  return { id: 'e1', data } as unknown as Entry
}

describe('inverseType', () => {
  it('flips the parent/child pair', () => {
    expect(inverseType('parent')).toBe('child')
    expect(inverseType('child')).toBe('parent')
  })

  it('is identity for symmetric types', () => {
    expect(inverseType('partner')).toBe('partner')
    expect(inverseType('sibling')).toBe('sibling')
    expect(inverseType('friend')).toBe('friend')
    expect(inverseType('colleague')).toBe('colleague')
  })
})

describe('relationLabel', () => {
  it('capitalizes the slug', () => {
    expect(relationLabel('friend')).toBe('Friend')
  })
})

describe('normalizeTags', () => {
  it('trims, lowercases, dedups and drops empties', () => {
    expect(normalizeTags([' Famille ', 'famille', 'LYON', '  '])).toEqual([
      'famille',
      'lyon'
    ])
  })

  it('rejects non-arrays and non-string items', () => {
    expect(normalizeTags('famille')).toEqual([])
    expect(normalizeTags(undefined)).toEqual([])
    expect(normalizeTags([42, null, 'ok'])).toEqual(['ok'])
  })
})

describe('tagsOf / relationsOf', () => {
  it('read defensively from entry data', () => {
    expect(tagsOf(entry({}))).toEqual([])
    expect(tagsOf(entry({ tags: ['A'] }))).toEqual(['a'])
    expect(relationsOf(entry({}))).toEqual([])
    expect(relationsOf(entry({ relations: 'x' }))).toEqual([])
  })

  it('keeps only well-formed relations with known types', () => {
    const rels = relationsOf(
      entry({
        relations: [
          { contact_id: 'a', type: 'friend' },
          { contact_id: 42, type: 'friend' },
          { contact_id: 'b', type: 'boss' },
          null
        ]
      })
    )
    expect(rels).toEqual([{ contact_id: 'a', type: 'friend' }])
  })
})

describe('withRelation / withoutRelation', () => {
  it('adds a relation', () => {
    expect(withRelation([], 'a', 'friend')).toEqual([
      { contact_id: 'a', type: 'friend' }
    ])
  })

  it('replaces the type of an existing relation to the same contact', () => {
    const cur = [
      { contact_id: 'a', type: 'friend' },
      { contact_id: 'b', type: 'parent' }
    ] as const
    expect(withRelation([...cur], 'a', 'colleague')).toEqual([
      { contact_id: 'b', type: 'parent' },
      { contact_id: 'a', type: 'colleague' }
    ])
  })

  it('removes only the matching relation', () => {
    const cur = [
      { contact_id: 'a', type: 'friend' },
      { contact_id: 'b', type: 'parent' }
    ] as const
    expect(withoutRelation([...cur], 'a')).toEqual([
      { contact_id: 'b', type: 'parent' }
    ])
    expect(withoutRelation([...cur], 'zz')).toEqual([...cur])
  })
})

describe('RELATION_TYPES', () => {
  it('is the fixed vocabulary', () => {
    expect([...RELATION_TYPES]).toEqual([
      'partner',
      'parent',
      'child',
      'sibling',
      'friend',
      'colleague'
    ])
  })
})
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `npx vitest run src/apps/contacts/relations.test.ts`
Expected: FAIL (cannot resolve `./relations`).

- [ ] **Step 3: Implement `relations.ts`**

`frontend/src/apps/contacts/relations.ts`:

```ts
// Tags and relations live in contact.data (schemaless entries). Safe across
// syncs: the CardDAV PUT merges data and the vCard connector never updates
// existing entries, so these keys survive phone edits and re-imports.
import type { Entry } from '../types'

export const RELATION_TYPES = [
  'partner',
  'parent',
  'child',
  'sibling',
  'friend',
  'colleague'
] as const

export type RelationType = (typeof RELATION_TYPES)[number]

export interface Relation {
  contact_id: string
  type: RelationType
}

export function relationLabel(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1)
}

// The stored type describes the linked contact relative to the entry that
// holds it ("parent" on Alice pointing at Bob = Bob is Alice's parent), so
// the reciprocal entry carries the inverse.
export function inverseType(type: RelationType): RelationType {
  if (type === 'parent') return 'child'
  if (type === 'child') return 'parent'
  return type
}

export function normalizeTags(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  const out: string[] = []
  for (const t of raw) {
    if (typeof t !== 'string') continue
    const tag = t.trim().toLowerCase()
    if (tag && !out.includes(tag)) out.push(tag)
  }
  return out
}

export function tagsOf(entry: Entry): string[] {
  return normalizeTags(entry.data.tags)
}

export function relationsOf(entry: Entry): Relation[] {
  const raw = entry.data.relations
  if (!Array.isArray(raw)) return []
  return raw.filter(
    (r): r is Relation =>
      !!r &&
      typeof r === 'object' &&
      typeof (r as Relation).contact_id === 'string' &&
      (RELATION_TYPES as readonly string[]).includes((r as Relation).type)
  )
}

export function withRelation(
  relations: Relation[],
  contactId: string,
  type: RelationType
): Relation[] {
  return [
    ...withoutRelation(relations, contactId),
    { contact_id: contactId, type }
  ]
}

export function withoutRelation(
  relations: Relation[],
  contactId: string
): Relation[] {
  return relations.filter(r => r.contact_id !== contactId)
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `npx vitest run src/apps/contacts/relations.test.ts`
Expected: PASS (all tests green).

- [ ] **Step 5: Format, type-check, commit**

```bash
npx prettier --write src/apps/contacts/relations.ts src/apps/contacts/relations.test.ts
npx vue-tsc --noEmit
git add src/apps/contacts/relations.ts src/apps/contacts/relations.test.ts
git commit -m "frontend: contacts relations module (tags + reciprocal relations logic)"
```

(Note for the test in Step 1: the two `as const` fixtures are spread into
mutable arrays before being passed; if vue-tsc still complains about
readonly types, type the fixtures `Relation[]` instead of `as const`.)

---

### Task 2: Tags (filter bar, header chips, immediate save)

**Files:**
- Modify: `frontend/src/apps/contacts/ContactsApp.vue`

**Interfaces:**
- Consumes from Task 1: `tagsOf(entry)`.
- Produces for Task 3: the pattern of immediate-save updates that refresh `allContacts` in place (Task 3 adds `saveRelations` alongside `saveTags`).

Current file landmarks (post commit 32e424d): the left column is
`.ct-list-col` with `.ct-search-wrap` at the top; view mode is the
`v-else-if="selected"` branch inside `.ct-detail-body`, whose header is
`.ct-detail-header` containing the avatar, a `<div>` with
`.ct-detail-name` + `.ct-detail-sub`, and the Edit button.

- [ ] **Step 1: Script additions**

Add the import (top of script, with the other `../../lib` imports):

```ts
import { tagsOf } from './relations'
```

After the `searchQuery` declaration, add:

```ts
const activeTag = ref<string | null>(null)
```

After the `filtered` computed, add:

```ts
const allTags = computed(() => {
  const set = new Set<string>()
  for (const c of allContacts.value) for (const t of tagsOf(c)) set.add(t)
  return [...set].sort()
})

function toggleTagFilter(tag: string) {
  activeTag.value = activeTag.value === tag ? null : tag
}
```

Replace the whole `filtered` computed with (tag filter ANDed with search,
search also matches tags):

```ts
const filtered = computed(() => {
  let list = allContacts.value
  if (activeTag.value) {
    list = list.filter(c => tagsOf(c).includes(activeTag.value!))
  }
  if (!searchQuery.value) return list
  const q = searchQuery.value.toLowerCase()
  return list.filter(c => {
    const name = contactName(c).toLowerCase()
    const org = fld(c, 'org').toLowerCase()
    const email = getEmails(c)
      .map(e => e.value.toLowerCase())
      .join(' ')
    const phone = getPhones(c)
      .map(p => p.value)
      .join(' ')
    const tags = tagsOf(c).join(' ')
    return (
      name.includes(q) ||
      org.includes(q) ||
      email.includes(q) ||
      phone.includes(q) ||
      tags.includes(q)
    )
  })
})
```

Next to the other view-mode actions (after `toggleBirthdayOnDashboard`), add:

```ts
const newTag = ref('')

async function saveTags(next: string[]) {
  const c = selected.value
  if (!c) return
  try {
    const updated = await props.ctx.api.entries.update(c.id, {
      data: { ...c.data, tags: next }
    })
    allContacts.value = allContacts.value.map(x =>
      x.id === updated.id ? updated : x
    )
  } catch {
    // chips reflect the server state again on the next load
  }
}

function addTag() {
  const c = selected.value
  const tag = newTag.value.trim().toLowerCase()
  newTag.value = ''
  if (!c || !tag) return
  const cur = tagsOf(c)
  if (cur.includes(tag)) return
  void saveTags([...cur, tag])
}

function removeTag(tag: string) {
  const c = selected.value
  if (!c) return
  void saveTags(tagsOf(c).filter(t => t !== tag))
}
```

- [ ] **Step 2: Template, left column tag bar**

Immediately after the closing `</div>` of `.ct-search-wrap`, insert:

```html
<div v-if="allTags.length" class="ct-tag-bar">
  <button
    v-for="t in allTags"
    :key="t"
    class="ct-tag-chip"
    :class="{ 'ct-tag-chip--active': t === activeTag }"
    @click="toggleTagFilter(t)"
  >
    {{ t }}
  </button>
</div>
```

- [ ] **Step 3: Template, header chips (view mode)**

Inside `.ct-detail-header`, in the `<div>` holding `.ct-detail-name` and
`.ct-detail-sub`, after the `ct-detail-sub` span, insert:

```html
<div class="ct-header-tags">
  <button
    v-for="t in tagsOf(selected)"
    :key="t"
    class="ct-tag-chip"
    @click="toggleTagFilter(t)"
  >
    {{ t }}
    <span class="ct-tag-x" title="Remove tag" @click.stop="removeTag(t)"
      >&times;</span
    >
  </button>
  <form class="ct-tag-add" @submit.prevent="addTag">
    <input v-model="newTag" list="ct-tag-options" placeholder="+ tag" />
    <datalist id="ct-tag-options">
      <option v-for="t in allTags" :key="t" :value="t" />
    </datalist>
  </form>
</div>
```

- [ ] **Step 4: Scoped CSS**

Add after the `.ct-search` rule:

```css
.ct-tag-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  padding: 0.6rem 0.75rem;
  border-bottom: 1px solid var(--border);
}
.ct-tag-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  padding: 0.15rem 0.6rem;
  border-radius: 999px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  font-size: 0.78rem;
  cursor: pointer;
}
.ct-tag-chip:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.ct-tag-chip--active {
  border-color: var(--primary);
  background: rgba(var(--primary-rgb), 0.12);
  color: var(--primary);
}
```

Add after the `.ct-detail-sub` rule (the global stylesheet gives inputs
`width: 100%` and heavy padding, hence the explicit overrides):

```css
.ct-header-tags {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.375rem;
  margin-top: 0.4rem;
}
.ct-tag-x {
  color: var(--text-muted);
  visibility: hidden;
}
.ct-tag-chip:hover .ct-tag-x {
  visibility: visible;
}
.ct-tag-x:hover {
  color: var(--danger);
}
.ct-tag-add input {
  width: 90px;
  padding: 0.15rem 0.5rem;
  font-size: 0.78rem;
  border-radius: 999px;
  background: transparent;
  border: 1px dashed var(--border);
}
.ct-tag-add input:focus {
  border-style: solid;
}
```

- [ ] **Step 5: Verify**

```bash
npx prettier --write src/apps/contacts/ContactsApp.vue
npx vue-tsc --noEmit
npx vitest run
```

Expected: prettier clean, no TS errors, all vitest suites PASS.

Manual sanity (optional, dev server): tag a contact, chip appears in the
left bar; click filters the list; the count in the topbar follows; search
"famille" matches tagged contacts; removing the last use of a tag removes
its chip from the bar.

- [ ] **Step 6: Commit**

```bash
git add src/apps/contacts/ContactsApp.vue
git commit -m "frontend: contact tags (chip filter bar, header chips, search match)"
```

---

### Task 3: Relations card (reciprocal add/remove, orphan cleanup)

**Files:**
- Modify: `frontend/src/apps/contacts/ContactsApp.vue`

**Interfaces:**
- Consumes from Task 1: `RELATION_TYPES`, `RelationType`, `Relation`, `relationLabel`, `inverseType`, `relationsOf`, `withRelation`, `withoutRelation`.
- Consumes from Task 2: the immediate-save pattern (update entry, refresh `allContacts` in place).

Semantics (from the spec): the stored type describes the linked contact
relative to the card it sits on. Adding "Parent - Bob" on Alice's card
means Bob is Alice's parent; Bob's card then shows "Child - Alice".

- [ ] **Step 1: Script additions**

Extend the Task 2 import to:

```ts
import {
  RELATION_TYPES,
  inverseType,
  relationLabel,
  relationsOf,
  tagsOf,
  withRelation,
  withoutRelation,
  type Relation,
  type RelationType
} from './relations'
```

After the tags functions (`removeTag`), add:

```ts
// ----- relations (reciprocal, saved immediately on both cards) -----

const newRelType = ref<RelationType>('friend')
const newRelName = ref('')

const relTargets = computed(() =>
  allContacts.value.filter(c => c.id !== selectedId.value)
)

const visibleRelations = computed(() => {
  if (!selected.value) return []
  return relationsOf(selected.value)
    .map(r => ({
      ...r,
      contact: allContacts.value.find(c => c.id === r.contact_id) || null
    }))
    .filter((r): r is Relation & { contact: Entry } => r.contact !== null)
})

async function saveRelations(target: Entry, next: Relation[]) {
  const updated = await props.ctx.api.entries.update(target.id, {
    data: { ...target.data, relations: next }
  })
  allContacts.value = allContacts.value.map(x =>
    x.id === updated.id ? updated : x
  )
}

async function addRelation() {
  const c = selected.value
  const name = newRelName.value.trim()
  if (!c || !name) return
  const target = relTargets.value.find(
    t => contactName(t).toLowerCase() === name.toLowerCase()
  )
  if (!target) return
  newRelName.value = ''
  try {
    await saveRelations(
      c,
      withRelation(relationsOf(c), target.id, newRelType.value)
    )
    await saveRelations(
      target,
      withRelation(relationsOf(target), c.id, inverseType(newRelType.value))
    )
  } catch {
    // a partial write settles on the next load
  }
}

async function removeRelation(contactId: string) {
  const c = selected.value
  if (!c) return
  try {
    await saveRelations(c, withoutRelation(relationsOf(c), contactId))
    const other = allContacts.value.find(x => x.id === contactId)
    if (other) {
      await saveRelations(other, withoutRelation(relationsOf(other), c.id))
    }
  } catch {
    // a partial write settles on the next load
  }
}
```

In `deleteContact`, after the line
`allContacts.value = allContacts.value.filter(x => x.id !== c.id)`, add the
best-effort orphan cleanup:

```ts
    for (const o of allContacts.value) {
      const rels = relationsOf(o)
      if (rels.some(r => r.contact_id === c.id)) {
        saveRelations(o, withoutRelation(rels, c.id)).catch(() => {})
      }
    }
```

- [ ] **Step 2: Template, Relations card**

Between the Parameters card (`v-if="fld(selected, 'birthday')"`) and the
Events card (`v-if="linkedEvents.length"`), insert (always visible, it
carries the add row):

```html
<div class="ct-section-card">
  <h3 class="ct-section-title">Relations</h3>
  <div
    v-for="r in visibleRelations"
    :key="r.contact_id"
    class="ct-linked-row"
    role="button"
    tabindex="0"
    @click="selectContact(r.contact_id)"
    @keydown.enter="selectContact(r.contact_id)"
  >
    <span class="ct-linked-meta">{{ relationLabel(r.type) }}</span>
    <span class="ct-linked-title">{{ contactName(r.contact) }}</span>
    <span
      class="ct-rel-x"
      title="Remove relation"
      @click.stop="removeRelation(r.contact_id)"
      >&times;</span
    >
  </div>
  <form class="ct-rel-add" @submit.prevent="addRelation">
    <select v-model="newRelType" class="ct-rel-type">
      <option v-for="t in RELATION_TYPES" :key="t" :value="t">
        {{ relationLabel(t) }}
      </option>
    </select>
    <input
      v-model="newRelName"
      class="ct-rel-name"
      list="ct-rel-options"
      placeholder="Contact name..."
    />
    <datalist id="ct-rel-options">
      <option v-for="t in relTargets" :key="t.id" :value="contactName(t)" />
    </datalist>
    <button type="submit" class="ct-rel-btn" :disabled="!newRelName.trim()">
      Link
    </button>
  </form>
</div>
```

- [ ] **Step 3: Scoped CSS**

Add after the `.ct-linked-row .ct-linked-meta:last-child` rule:

```css
.ct-rel-x {
  margin-left: auto;
  padding: 0 0.25rem;
  color: var(--text-muted);
  visibility: hidden;
}
.ct-linked-row:hover .ct-rel-x {
  visibility: visible;
}
.ct-rel-x:hover {
  color: var(--danger);
}
.ct-rel-add {
  display: flex;
  gap: 0.375rem;
  margin-top: 0.6rem;
}
.ct-rel-type {
  width: 110px;
  flex-shrink: 0;
}
.ct-rel-name {
  flex: 1;
  min-width: 0;
}
.ct-rel-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
  flex-shrink: 0;
}
.ct-rel-btn:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.ct-rel-btn:disabled {
  opacity: 0.5;
  cursor: default;
}
```

Note: `.ct-linked-row` already exists (Events / Mentioned in) and keeps its
`.ct-linked-meta:last-child { margin-left: auto }` rule; in relation rows
the last child is `.ct-rel-x`, so that rule does not apply there and the
type label stays left of the name, matching the Events rows.

- [ ] **Step 4: Verify**

```bash
npx prettier --write src/apps/contacts/ContactsApp.vue
npx vue-tsc --noEmit
npx vitest run
```

Expected: prettier clean, no TS errors, all vitest suites PASS.

Manual sanity (optional, dev server): on Alice pick "Parent" + type Bob's
name + Link; Alice shows "Parent - Bob"; open Bob, his card shows
"Child - Alice"; the × on either side removes both; deleting Bob removes
the row from Alice; linking a contact to itself is impossible (own name is
not in the datalist and exact-match resolution excludes the selected id).

- [ ] **Step 5: Commit**

```bash
git add src/apps/contacts/ContactsApp.vue
git commit -m "frontend: contact relations card (fixed types, reciprocal saves)"
```
