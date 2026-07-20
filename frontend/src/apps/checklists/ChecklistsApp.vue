<script setup lang="ts">
import {
  ref,
  reactive,
  computed,
  nextTick,
  onMounted,
  onBeforeUnmount
} from 'vue'
import AutocompleteInput from '../../components/AutocompleteInput.vue'
import DateInput from '../../components/DateInput.vue'
import type { AppContext, Entry } from '../types'
import { createFolderOrder } from '../folderOrder'
import { itemsToMarkdown, parseListText, type Item } from './markdown'

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const folderOrder = createFolderOrder(ctx, 'checklists')

// ----- helpers -----

const folderOf = (l: Entry) => ((l.data.folder as string) || '').trim()
const itemsOf = (l: Entry) => (l.data.items as Item[]) || []
const doneCount = (l: Entry) => itemsOf(l).filter(i => i.done).length
const isRecurring = (l: Entry) => l.data.recurring === true
const isOnDashboard = (l: Entry) => l.data.show_on_dashboard === true

function ensureItems(l: Entry): Item[] {
  if (!Array.isArray(l.data.items)) l.data.items = []
  return l.data.items as Item[]
}

// ----- reactive state -----

const lists = ref<Entry[]>([])
const selectedId = ref<string | null>(null)
const searchQuery = ref('')
const collapsed = reactive(new Set<string>())
const loadState = ref<'loading' | 'ready' | 'error'>('loading')
const newItemText = ref('')
const saveState = ref<'idle' | 'saving' | 'saved' | 'error'>('idle')
const saveError = ref('')

const selected = computed(
  () => lists.value.find(l => l.id === selectedId.value) || null
)
const items = computed(() => (selected.value ? itemsOf(selected.value) : []))
const recurring = computed(
  () => !!selected.value && isRecurring(selected.value)
)
const onDashboard = computed(
  () => !!selected.value && isOnDashboard(selected.value)
)

const editTitle = computed({
  get: () => selected.value?.title || '',
  set: (v: string) => {
    if (selected.value) selected.value.title = v
  }
})
const editFolder = computed({
  get: () => (selected.value?.data.folder as string) || '',
  set: (v: string) => {
    if (selected.value) selected.value.data.folder = v
  }
})

function onFolderInput(v: string) {
  editFolder.value = v
  scheduleSave()
}

const saveStatusLabel = computed(() => {
  if (saveState.value === 'error') return saveError.value || 'Save failed'
  return { idle: '', saving: 'Saving…', saved: 'Saved' }[saveState.value] || ''
})

// ----- sidebar rows (single-level folders) -----

const filtered = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) return lists.value
  return lists.value.filter(l =>
    [l.title || '', folderOf(l), ...itemsOf(l).map(i => i.text)]
      .join(' ')
      .toLowerCase()
      .includes(q)
  )
})

interface Row {
  kind: 'folder' | 'list'
  name: string
  list?: Entry
  collapsed?: boolean
  depth: number
}

const rows = computed<Row[]>(() => {
  const searching = !!searchQuery.value.trim()
  const byFolder = new Map<string, Entry[]>()
  for (const l of filtered.value) {
    const f = folderOf(l)
    if (!byFolder.has(f)) byFolder.set(f, [])
    byFolder.get(f)!.push(l)
  }
  const sortLists = (ls: Entry[]) =>
    [...ls].sort((a, b) =>
      (a.title || '').toLowerCase().localeCompare((b.title || '').toLowerCase())
    )

  const out: Row[] = []
  for (const l of sortLists(byFolder.get('') || [])) {
    out.push({ kind: 'list', name: l.title || 'Untitled', list: l, depth: 0 })
  }
  const folders = [...byFolder.keys()].filter(Boolean).sort(folderOrder.compare)
  for (const f of folders) {
    const isCollapsed = !searching && collapsed.has(f)
    out.push({ kind: 'folder', name: f, collapsed: isCollapsed, depth: 0 })
    if (!isCollapsed) {
      for (const l of sortLists(byFolder.get(f)!)) {
        out.push({
          kind: 'list',
          name: l.title || 'Untitled',
          list: l,
          depth: 1
        })
      }
    }
  }
  return out
})

function toggleFolder(name: string) {
  if (collapsed.has(name)) collapsed.delete(name)
  else collapsed.add(name)
}

// ----- folder rename -----

const renamingFolder = ref<string | null>(null)
const renameValue = ref('')

async function startRenameFolder(name: string) {
  renamingFolder.value = name
  renameValue.value = name
  await nextTick()
  const el = document.querySelector(
    '.cl-folder-rename'
  ) as HTMLInputElement | null
  el?.focus()
  el?.select()
}

function commitRenameFolder() {
  const from = renamingFolder.value
  const to = renameValue.value.trim()
  renamingFolder.value = null
  if (!from || !to || to === from) return
  for (const l of lists.value.filter(x => folderOf(x) === from)) {
    l.data.folder = to
    void save(l)
  }
  folderOrder.rename(from, to)
}

// ----- drag & drop (move a checklist into a folder / to the root,
//       drag a folder onto another folder to reorder) -----

const draggingId = ref<string | null>(null)
const draggingFolder = ref<string | null>(null)
const dragOverFolder = ref<string | null>(null)

const allFolders = computed(() =>
  [...new Set(lists.value.map(folderOf).filter(Boolean))].sort(
    folderOrder.compare
  )
)

function onDragStart(l: Entry, e: DragEvent) {
  draggingId.value = l.id
  e.dataTransfer?.setData('text/plain', l.id)
  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move'
}

function onFolderDragStart(name: string, e: DragEvent) {
  draggingFolder.value = name
  e.dataTransfer?.setData('text/plain', name)
  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move'
}

function onDrop(target: string) {
  dragOverFolder.value = null

  if (draggingFolder.value) {
    // Reorder: insert the dragged folder before the target (end when dropped
    // on the tree background).
    const from = draggingFolder.value
    draggingFolder.value = null
    if (from === target) return
    const seq = allFolders.value.filter(f => f !== from)
    const idx = target ? seq.indexOf(target) : seq.length
    seq.splice(idx === -1 ? seq.length : idx, 0, from)
    folderOrder.setGroup(seq)
    return
  }

  const l = lists.value.find(x => x.id === draggingId.value)
  draggingId.value = null
  if (!l || folderOf(l) === target.trim()) return
  l.data.folder = target
  void save(l)
}

// ----- save (debounced for text edits, immediate for structural ones, serialized) -----

let saveTimer: ReturnType<typeof setTimeout> | undefined
let pending: Entry | null = null
let saveChain: Promise<void> = Promise.resolve()

function save(l: Entry): Promise<void> {
  saveState.value = 'saving'
  saveChain = saveChain
    .then(() => ctx.api.entries.update(l.id, { title: l.title, data: l.data }))
    .then(() => {
      saveState.value = 'saved'
      saveError.value = ''
    })
    .catch(e => {
      saveState.value = 'error'
      saveError.value = e instanceof Error ? e.message : 'Save failed'
    })
  return saveChain
}

function flushPending() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = undefined
  if (pending) {
    const l = pending
    pending = null
    void save(l)
  }
}

function scheduleSave() {
  if (!selected.value) return
  pending = selected.value
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(flushPending, 600)
}

function saveNow() {
  if (!selected.value) return
  pending = selected.value
  flushPending()
}

onBeforeUnmount(flushPending)

// ----- selection / CRUD -----

function selectList(id: string, opts: { push?: boolean } = {}) {
  flushPending()
  saveState.value = 'idle'
  saveError.value = ''
  newItemText.value = ''
  dueEditIndex.value = null
  selectedId.value = id
  if (opts.push !== false) {
    history.pushState(null, '', `/apps/checklists?selected=${id}`)
  }
}

function onPopState() {
  flushPending()
  const id = new URLSearchParams(window.location.search).get('selected')
  if (id) selectList(id, { push: false })
  else selectedId.value = null
}

function uniqueTitle(base: string): string {
  const existing = new Set(lists.value.map(l => (l.title || '').toLowerCase()))
  if (!existing.has(base.toLowerCase())) return base
  let i = 2
  while (existing.has(`${base} ${i}`.toLowerCase())) i++
  return `${base} ${i}`
}

async function createList(folder = '') {
  flushPending()
  try {
    const created = await ctx.api.entries.create({
      kind: 'checklist',
      source: 'manual',
      title: uniqueTitle('Untitled'),
      data: { folder, recurring: false, items: [] }
    })
    lists.value.push(created)
    selectList(created.id)
    await nextTick()
    const el = document.querySelector('.cl-title') as HTMLInputElement | null
    el?.focus()
    el?.select()
  } catch {
    // ignore
  }
}

async function deleteSelected() {
  const l = selected.value
  if (!l) return
  const ok = await ctx.confirm.ask({
    title: 'Delete checklist',
    message: `Delete "${l.title || 'Untitled'}"? This cannot be undone.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  try {
    await ctx.api.entries.delete(l.id)
    lists.value = lists.value.filter(x => x.id !== l.id)
    if (selectedId.value === l.id) {
      selectedId.value = null
      history.replaceState(null, '', '/apps/checklists')
    }
  } catch {
    // ignore
  }
}

// ----- item / recurring actions -----

function addItem() {
  const l = selected.value
  const text = newItemText.value.trim()
  if (!l || !text) return
  ensureItems(l).push({ text, done: false })
  newItemText.value = ''
  saveNow()
}

function removeItem(index: number) {
  const l = selected.value
  if (!l) return
  ensureItems(l).splice(index, 1)
  saveNow()
}

// ----- deadlines -----

const dueEditIndex = ref<number | null>(null)

function setDue(item: Item, due: string) {
  if (due) item.due = due
  else delete item.due
  dueEditIndex.value = null
  saveNow()
}

function clearDue(item: Item) {
  delete item.due
  dueEditIndex.value = null
  saveNow()
}

// Local civil date; a deadline is a day, not an instant.
function todayStr(): string {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, '0')}`
}

function overdue(item: Item): boolean {
  return !!item.due && !item.done && item.due < todayStr()
}

function formatDue(due: string): string {
  const [y, m, d] = due.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC'
  })
}

// Tab indents an item one level, Shift+Tab brings it back (outliner
// convention). One sub-level only.
// ponytail: indent is per-item cosmetic; drag-reorder and "Done last" can
// separate a sub-item from its parent. Group moves if that ever hurts.
function setIndent(item: Item, e: KeyboardEvent) {
  const to = e.shiftKey ? 0 : 1
  if ((item.indent || 0) === to) return
  if (to) item.indent = to
  else delete item.indent
  saveNow()
}

// ----- item reordering (drag the grip onto another row) -----

const dragIndex = ref<number | null>(null)
const dropIndex = ref<number | null>(null)

function onItemDragStart(i: number, e: DragEvent) {
  dragIndex.value = i
  if (e.dataTransfer) {
    e.dataTransfer.setData('text/plain', String(i))
    e.dataTransfer.effectAllowed = 'move'
  }
}

function onItemDragOver(i: number, e: DragEvent) {
  if (dragIndex.value === null) return
  e.preventDefault()
  if (e.dataTransfer) e.dataTransfer.dropEffect = 'move'
  dropIndex.value = i
}

function onItemDrop(i: number) {
  const from = dragIndex.value
  dropIndex.value = null
  const l = selected.value
  if (from === null || from === i || !l) return
  const arr = ensureItems(l)
  const [moved] = arr.splice(from, 1)
  arr.splice(i, 0, moved)
  saveNow()
}

function onItemDragEnd() {
  dragIndex.value = null
  dropIndex.value = null
}

// ----- export / copy / paste import -----

const copied = ref(false)
let copiedTimer: ReturnType<typeof setTimeout> | undefined

function exportJson() {
  const l = selected.value
  if (!l) return
  const payload = {
    title: l.title || 'Untitled',
    folder: folderOf(l),
    recurring: isRecurring(l),
    items: itemsOf(l)
  }
  const blob = new Blob([JSON.stringify(payload, null, 2)], {
    type: 'application/json'
  })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = `${(l.title || 'checklist').replace(/[/\\:*?"<>|]/g, '_')}.json`
  a.click()
  URL.revokeObjectURL(a.href)
}

async function copyMarkdown() {
  const l = selected.value
  if (!l) return
  try {
    await navigator.clipboard.writeText(itemsToMarkdown(itemsOf(l)))
  } catch {
    return
  }
  copied.value = true
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => (copied.value = false), 1500)
}

// Pasting a bullet / checkbox list into the add field imports one item per
// line; anything that is not a list pastes normally.
function onAddPaste(e: ClipboardEvent) {
  const l = selected.value
  const parsed = parseListText(e.clipboardData?.getData('text/plain') || '')
  if (!l || !parsed) return
  e.preventDefault()
  ensureItems(l).push(...parsed)
  saveNow()
}

function resetList() {
  const l = selected.value
  if (!l) return
  for (const item of ensureItems(l)) item.done = false
  saveNow()
}

// Stable partition: pending items keep their order, done ones sink.
function sortDoneLast() {
  const l = selected.value
  if (!l) return
  const arr = ensureItems(l)
  l.data.items = [...arr.filter(i => !i.done), ...arr.filter(i => i.done)]
  saveNow()
}

function toggleRecurring(e: Event) {
  const l = selected.value
  if (!l) return
  l.data.recurring = (e.target as HTMLInputElement).checked
  saveNow()
}

function toggleOnDashboard(e: Event) {
  const l = selected.value
  if (!l) return
  l.data.show_on_dashboard = (e.target as HTMLInputElement).checked
  saveNow()
}

// ----- load -----

onMounted(async () => {
  window.addEventListener('popstate', onPopState)
  void folderOrder.load()
  try {
    lists.value = await ctx.api.entries.list({ kind: 'checklist' })
    loadState.value = 'ready'
  } catch {
    loadState.value = 'error'
  }
  const initial = new URLSearchParams(window.location.search).get('selected')
  if (initial && lists.value.some(l => l.id === initial)) {
    selectList(initial, { push: false })
  }
})
onBeforeUnmount(() => window.removeEventListener('popstate', onPopState))
</script>

<template>
  <div class="cl-layout">
    <div class="cl-sidebar">
      <div class="cl-side-head">
        <input
          class="cl-search"
          type="text"
          placeholder="Search checklists..."
          v-model="searchQuery"
        />
      </div>
      <div class="cl-tree" @dragover.prevent @drop.prevent="onDrop('')">
        <template v-if="rows.length">
          <div
            v-for="row in rows"
            :key="row.kind === 'folder' ? 'f:' + row.name : 'l:' + row.list!.id"
          >
            <div
              v-if="row.kind === 'folder'"
              class="cl-folder"
              :class="{ 'cl-folder--drop': dragOverFolder === row.name }"
              draggable="true"
              @click="toggleFolder(row.name)"
              @dragstart="onFolderDragStart(row.name, $event)"
              @dragend="draggingFolder = null"
              @dragover.prevent="dragOverFolder = row.name"
              @dragleave="dragOverFolder = null"
              @drop.prevent.stop="onDrop(row.name)"
            >
              <span class="cl-folder-caret">{{
                row.collapsed ? '▸' : '▾'
              }}</span>
              <input
                v-if="renamingFolder === row.name"
                class="cl-folder-rename"
                v-model="renameValue"
                @click.stop
                @keyup.enter="commitRenameFolder"
                @keyup.esc="renamingFolder = null"
                @blur="commitRenameFolder"
              />
              <template v-else>
                <span class="cl-folder-name">{{ row.name }}</span>
                <button
                  class="cl-folder-edit"
                  title="Rename folder"
                  @click.stop="startRenameFolder(row.name)"
                >
                  ✎
                </button>
              </template>
            </div>
            <div
              v-else
              class="cl-row"
              :class="{ 'cl-row--active': row.list!.id === selectedId }"
              :style="{ paddingLeft: row.depth * 12 + 8 + 'px' }"
              draggable="true"
              @dragstart="onDragStart(row.list!, $event)"
              @dragend="draggingId = null"
              @dragover.prevent
              @drop.prevent.stop="onDrop(folderOf(row.list!))"
              @click="selectList(row.list!.id)"
            >
              <span class="cl-row-title">
                <span
                  v-if="isRecurring(row.list!)"
                  class="cl-row-recurring"
                  title="Recurring"
                  >↻</span
                >
                {{ row.name }}
              </span>
              <span v-if="itemsOf(row.list!).length" class="cl-row-count">
                {{ doneCount(row.list!) }}/{{ itemsOf(row.list!).length }}
              </span>
            </div>
          </div>
        </template>
        <p v-else class="cl-empty">
          {{
            loadState === 'error'
              ? 'Failed to load checklists.'
              : 'No checklists yet.'
          }}
        </p>
      </div>
    </div>

    <div class="cl-main">
      <div class="cl-main-topbar">
        <span class="cl-count"
          >{{ filtered.length }}
          <span class="cl-count-unit">{{
            filtered.length === 1 ? 'CHECKLIST' : 'CHECKLISTS'
          }}</span></span
        >
        <button class="cl-new-btn" @click="createList()">
          <svg
            width="15"
            height="15"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M12 5v14M5 12h14" />
          </svg>
          New checklist
        </button>
      </div>
      <p v-if="loadState === 'loading'" class="cl-placeholder">
        Loading checklists…
      </p>
      <p v-else-if="!selected" class="cl-placeholder">
        Select or create a checklist to get started.
      </p>
      <template v-else>
        <div class="cl-toolbar">
          <div class="cl-toolbar-row">
            <input
              class="cl-title"
              v-model="editTitle"
              placeholder="Untitled"
              @input="scheduleSave()"
            />
            <span
              class="cl-save-status"
              :class="{ 'cl-save-status--error': saveState === 'error' }"
              :title="saveState === 'error' ? saveError : ''"
              >{{ saveStatusLabel }}</span
            >
            <button
              class="cl-delete"
              title="Delete checklist"
              @click="deleteSelected"
            >
              🗑
            </button>
          </div>
          <div class="cl-toolbar-row">
            <AutocompleteInput
              class="cl-folder-input"
              :model-value="editFolder"
              :options="allFolders"
              placeholder="Folder"
              @update:model-value="onFolderInput"
              @select="saveNow()"
            />
            <label
              class="cl-recurring-toggle"
              title="Recurring lists can be reset"
            >
              <input
                type="checkbox"
                :checked="recurring"
                @change="toggleRecurring"
              />
              Recurring
            </label>
            <label
              class="cl-recurring-toggle"
              title="Show pending items on the dashboard"
            >
              <input
                type="checkbox"
                :checked="onDashboard"
                @change="toggleOnDashboard"
              />
              Dashboard
            </label>
            <span class="cl-toolbar-spacer"></span>
            <button
              v-if="doneCount(selected) > 0"
              class="cl-sort-btn"
              title="Move completed items to the bottom"
              @click="sortDoneLast"
            >
              ⇩ Done last
            </button>
            <button
              v-if="recurring"
              class="cl-reset-btn"
              title="Uncheck all items"
              @click="resetList"
            >
              ↻ Reset
            </button>
            <button
              class="cl-copy-btn"
              title="Copy as a markdown checkbox list"
              @click="copyMarkdown"
            >
              {{ copied ? '✓ Copied' : '⧉ Copy' }}
            </button>
            <button
              class="cl-export-btn"
              title="Download as JSON"
              @click="exportJson"
            >
              ⤓ JSON
            </button>
          </div>
        </div>

        <div class="cl-items">
          <div v-if="items.length" class="cl-progress">
            {{ doneCount(selected) }}/{{ items.length }} done
          </div>
          <div
            v-for="(item, i) in items"
            :key="i"
            class="cl-item"
            :class="{
              'cl-item--done': item.done,
              'cl-item--sub': !!item.indent,
              'cl-item--dragging': dragIndex === i,
              'cl-item--droptarget': dropIndex === i && dragIndex !== i
            }"
            @dragover="onItemDragOver(i, $event)"
            @dragleave="dropIndex === i && (dropIndex = null)"
            @drop.prevent="onItemDrop(i)"
          >
            <span
              class="cl-item-grip"
              draggable="true"
              title="Drag to reorder"
              aria-label="Drag to reorder"
              @dragstart="onItemDragStart(i, $event)"
              @dragend="onItemDragEnd"
              >⋮⋮</span
            >
            <input type="checkbox" v-model="item.done" @change="saveNow()" />
            <input
              class="cl-item-text"
              v-model="item.text"
              @input="scheduleSave()"
              @keydown.tab.prevent="setIndent(item, $event)"
            />
            <template v-if="dueEditIndex === i">
              <DateInput
                class="cl-due-input"
                :model-value="item.due || ''"
                title="Deadline"
                @update:model-value="setDue(item, $event)"
              />
              <button
                class="cl-due-clear"
                title="Remove deadline"
                @click="clearDue(item)"
              >
                ×
              </button>
            </template>
            <button
              v-else-if="item.due"
              class="cl-due-chip"
              :class="{ 'cl-due-chip--overdue': overdue(item) }"
              :title="'Deadline ' + item.due"
              @click="dueEditIndex = i"
            >
              {{ formatDue(item.due) }}
            </button>
            <button
              v-else
              class="cl-item-due-btn"
              title="Set a deadline"
              @click="dueEditIndex = i"
            >
              🗓
            </button>
            <button
              class="cl-item-del"
              title="Remove item"
              @click="removeItem(i)"
            >
              ×
            </button>
          </div>
          <form class="cl-add" @submit.prevent="addItem">
            <input
              class="cl-add-input"
              v-model="newItemText"
              placeholder="Add an item…"
              title="Paste a bullet or checkbox list to add one item per line"
              @paste="onAddPaste"
            />
            <button
              type="submit"
              class="cl-add-btn"
              :disabled="!newItemText.trim()"
            >
              Add
            </button>
          </form>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.cl-layout {
  display: flex;
  height: calc(100vh - 4rem);
}
.cl-sidebar {
  width: 280px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
}
.cl-side-head {
  display: flex;
  gap: 0.5rem;
  padding: 0.75rem;
  border-bottom: 1px solid var(--border);
}
.cl-search {
  flex: 1;
  min-width: 0;
}
.cl-main-topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.cl-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  color: var(--text);
  white-space: nowrap;
}
.cl-count-unit {
  color: var(--text-muted);
  letter-spacing: 0.08em;
}
.cl-new-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  height: 32px;
  padding: 0 0.75rem;
  flex-shrink: 0;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  font-size: 0.85rem;
  border-radius: 8px;
  cursor: pointer;
}
.cl-new-btn:hover,
.cl-new-btn:focus-visible {
  border-color: var(--primary);
  color: var(--primary);
}
.cl-tree {
  flex: 1;
  overflow-y: auto;
  padding: 0.375rem 0.25rem;
}
.cl-folder {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.3rem 0.4rem;
  border-radius: 6px;
  cursor: pointer;
  color: var(--text-muted);
  font-size: 0.9rem;
}
.cl-folder:hover {
  background: var(--bg-hover);
}
.cl-folder-caret {
  width: 0.9em;
  flex-shrink: 0;
}
.cl-folder--drop {
  background: var(--bg-hover);
  color: var(--primary);
}
.cl-folder-name {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cl-folder-edit {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.25rem;
  font-size: 0.8rem;
  visibility: hidden;
}
.cl-folder:hover .cl-folder-edit {
  visibility: visible;
}
.cl-folder-edit:hover {
  color: var(--primary);
}
.cl-folder-rename {
  flex: 1;
  min-width: 0;
  padding: 0.15rem 0.4rem;
  font-size: 0.85rem;
  border-radius: 6px;
}
.cl-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.3rem 0.4rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.9rem;
}
.cl-row:hover {
  background: var(--bg-hover);
}
/* Cursor row: violet rail + tint, same language as Contacts/Files */
.cl-row--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 6px 6px 0;
}
.cl-row-title {
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cl-row-recurring {
  color: var(--text-muted);
}
.cl-row-count {
  font-size: 0.75rem;
  color: var(--text-muted);
  flex-shrink: 0;
}
.cl-empty,
.cl-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 2.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}
.cl-main {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.cl-toolbar {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.75rem;
  border-bottom: 1px solid var(--border);
}
.cl-toolbar-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.cl-toolbar-spacer {
  flex: 1;
}
.cl-title {
  flex: 1;
  min-width: 0;
  font-weight: 600;
  font-size: 1.05rem;
}
.cl-folder-input {
  width: 200px;
  flex-shrink: 0;
}
.cl-save-status {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.cl-save-status--error {
  color: var(--danger);
}
.cl-recurring-toggle {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.85rem;
  color: var(--text-muted);
  white-space: nowrap;
  cursor: pointer;
}
.cl-reset-btn,
.cl-sort-btn,
.cl-copy-btn,
.cl-export-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.7rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
  white-space: nowrap;
}
.cl-reset-btn:hover,
.cl-sort-btn:hover,
.cl-copy-btn:hover,
.cl-export-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.cl-delete {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 8px;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
}
.cl-delete:hover {
  border-color: var(--danger);
  color: var(--danger);
}
.cl-items {
  flex: 1;
  overflow-y: auto;
  padding: 1rem 1.25rem;
  max-width: 640px;
}
/* Status readout: 3/7 DONE */
.cl-progress {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  margin-bottom: 0.6rem;
}
.cl-item {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.15rem 0;
}
/* Reorder grip: invisible until the row is hovered */
.cl-item-grip {
  cursor: grab;
  color: var(--text-muted);
  font-size: 0.75rem;
  letter-spacing: -2px;
  user-select: none;
  flex-shrink: 0;
  opacity: 0;
  transition: opacity 0.1s;
}
.cl-item:hover .cl-item-grip {
  opacity: 1;
}
.cl-item--sub {
  margin-left: 1.75rem;
}
.cl-item--dragging {
  opacity: 0.4;
}
/* Insertion mark: the dragged item will land in this slot */
.cl-item--droptarget {
  box-shadow: inset 0 2px 0 var(--primary);
}
/* The global stylesheet gives every input width:100% + heavy padding; undo it
   for checkboxes, and draw them in the terminal language: square cell,
   phosphor fill + dark check when on. */
.cl-item input[type='checkbox'],
.cl-recurring-toggle input {
  appearance: none;
  -webkit-appearance: none;
  width: 16px;
  height: 16px;
  padding: 0;
  margin: 0;
  flex-shrink: 0;
  border: 1.5px solid var(--border);
  border-radius: 4px;
  background: var(--bg);
  cursor: pointer;
  transition:
    border-color 0.12s,
    background 0.12s,
    box-shadow 0.12s;
}
.cl-item input[type='checkbox']:hover,
.cl-recurring-toggle input:hover {
  border-color: var(--primary);
}
.cl-item input[type='checkbox']:checked,
.cl-recurring-toggle input:checked {
  border-color: var(--primary);
  background-color: var(--primary);
  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath fill='none' stroke='%2305070f' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round' d='M3.5 8.5l3 3 6-7'/%3E%3C/svg%3E");
  background-size: 12px;
  background-position: center;
  background-repeat: no-repeat;
  box-shadow: 0 0 8px rgba(var(--primary-rgb), 0.4);
}
.cl-item-text {
  flex: 1;
  min-width: 0;
  padding: 0.3rem 0.5rem;
  font-size: 0.95rem;
  border-radius: 6px;
  background: transparent;
  border: 1px solid transparent;
}
.cl-item-text:hover,
.cl-item-text:focus {
  border-color: var(--border);
}
.cl-item--done .cl-item-text {
  text-decoration: line-through;
  color: var(--text-muted);
}
.cl-item-del {
  border: none;
  background: transparent;
  color: var(--text-muted);
  font-size: 1rem;
  cursor: pointer;
  padding: 0 0.25rem;
  visibility: hidden;
}
.cl-item:hover .cl-item-del {
  visibility: visible;
}
.cl-item-del:hover {
  color: var(--danger);
}
.cl-due-chip {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 999px;
  padding: 0.05rem 0.5rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  letter-spacing: 0.04em;
  cursor: pointer;
  flex-shrink: 0;
  white-space: nowrap;
}
.cl-due-chip:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.cl-due-chip--overdue {
  color: var(--danger);
  border-color: var(--danger);
}
.cl-item-due-btn {
  border: none;
  background: transparent;
  color: var(--text-muted);
  font-size: 0.8rem;
  cursor: pointer;
  padding: 0 0.25rem;
  visibility: hidden;
  flex-shrink: 0;
}
.cl-item:hover .cl-item-due-btn {
  visibility: visible;
}
.cl-item-due-btn:hover {
  color: var(--primary);
}
.cl-due-input {
  width: 110px;
  flex-shrink: 0;
  padding: 0.15rem 0.4rem;
  font-size: 0.8rem;
  border-radius: 6px;
}
.cl-due-clear {
  border: none;
  background: transparent;
  color: var(--text-muted);
  font-size: 1rem;
  cursor: pointer;
  padding: 0 0.25rem;
  flex-shrink: 0;
}
.cl-due-clear:hover {
  color: var(--danger);
}
.cl-add {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.75rem;
}
.cl-add-input {
  flex: 1;
  min-width: 0;
}
.cl-add-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
}
.cl-add-btn:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.cl-add-btn:disabled {
  opacity: 0.5;
  cursor: default;
}
</style>
