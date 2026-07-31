<script setup lang="ts">
import {
  ref,
  reactive,
  computed,
  onMounted,
  onBeforeUnmount,
  nextTick,
  watch
} from 'vue'
import { Star } from 'lucide-vue-next'
import AutocompleteInput from '../../components/AutocompleteInput.vue'
import type { AppContext, Entry } from '../types'
import { todayInUserTz, formatDate } from '../../lib/datetime'
import { renderMarkdown, canon, continueListEdit } from './render'
import { createFolderOrder } from '../folderOrder'

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const folderOrder = createFolderOrder(ctx, 'notes')

type Note = Entry

interface Mentionable {
  id: string
  kind: 'contact' | 'event'
  name: string
}

// ----- pure helpers (mirror the backend) -----

const noteFolder = (n: Note) => ((n.data.folder as string) || '').trim()
const noteBody = (n: Note) => (n.data.body as string) || ''
const noteTags = (n: Note) => (n.data.tags as string[]) || []
const noteFavorite = (n: Note) => n.data.favorite === true
const fullPath = (folder: string, title: string) =>
  folder ? `${folder}/${title}` : title

// A note is reachable as `[[title]]` or `[[folder/title]]`.
function noteKeys(n: Note): string[] {
  const title = n.title || ''
  return [canon(title), canon(fullPath(noteFolder(n), title))]
}

// vcard contact titles look like "Name - org - email" (pre-July 2026 entries
// used " — "); prefer the display name.
function mentionName(e: Entry): string {
  return (
    (e.data.display_name as string) ||
    (e.title || '').split(/ - | — /)[0] ||
    ''
  ).trim()
}

function dedupeByName(list: Mentionable[]): Mentionable[] {
  const seen = new Set<string>()
  return list.filter(m => {
    const k = canon(m.name)
    if (!m.name || seen.has(k)) return false
    seen.add(k)
    return true
  })
}

// ----- reactive state -----

const LAST_OPEN_KEY = 'servant_notes_last_open'

const notes = ref<Note[]>([])
const mentionables = ref<Mentionable[]>([])
const selectedId = ref<string | null>(null)
const backlinks = ref<Note[]>([])
const searchQuery = ref('')
const viewMode = ref<'split' | 'edit' | 'preview'>('split')
const collapsed = reactive(new Set<string>())
const loadState = ref<'loading' | 'ready' | 'error'>('loading')

// Editor fields (synced from the selected note on selection change).
const editTitle = ref('')
const editFolder = ref('')
const editBody = ref('')

const saveState = ref<'idle' | 'saving' | 'saved' | 'error'>('idle')
const saveError = ref('')

const bodyRef = ref<HTMLTextAreaElement | null>(null)

const selected = computed(
  () => notes.value.find(n => n.id === selectedId.value) || null
)

const createdLabel = computed(() =>
  selected.value ? formatDate(selected.value.inserted_at) : ''
)

const showEditor = computed(() => viewMode.value !== 'preview')
const showPreview = computed(() => viewMode.value !== 'edit')

// ----- API -----

async function apiList(): Promise<Note[]> {
  const res = await ctx.api.fetch('/api/notes')
  return (await res.json()).data
}
async function apiCreate(attrs: Record<string, unknown>): Promise<Note> {
  const res = await ctx.api.fetch('/api/notes', {
    method: 'POST',
    body: JSON.stringify(attrs)
  })
  return (await res.json()).data
}
async function apiUpdate(
  id: string,
  attrs: Record<string, unknown>
): Promise<Note> {
  const res = await ctx.api.fetch(`/api/notes/${id}`, {
    method: 'PUT',
    body: JSON.stringify(attrs)
  })
  return (await res.json()).data
}
async function apiDelete(id: string): Promise<void> {
  await ctx.api.fetch(`/api/notes/${id}`, { method: 'DELETE' })
}
async function apiBacklinks(id: string): Promise<Note[]> {
  const res = await ctx.api.fetch(`/api/notes/${id}/backlinks`)
  return (await res.json()).data
}

// ----- derived: tree, search, resolution -----

function resolveTargetNote(target: string): Note | null {
  const c = canon(target)
  return notes.value.find(n => noteKeys(n).includes(c)) || null
}
function resolveMention(target: string): Mentionable | null {
  const c = canon(target)
  return mentionables.value.find(m => canon(m.name) === c) || null
}

const filteredNotes = computed(() => {
  if (!searchQuery.value.trim()) return notes.value
  const q = searchQuery.value.toLowerCase()
  return notes.value.filter(n =>
    [n.title || '', noteFolder(n), noteBody(n), noteTags(n).join(' ')]
      .join(' ')
      .toLowerCase()
      .includes(q)
  )
})

function sortNotes(list: Note[]): Note[] {
  return [...list].sort((a, b) =>
    (a.title || '').toLowerCase().localeCompare((b.title || '').toLowerCase())
  )
}

// Pinned above the folder tree; the notes also keep their place in it.
const favoriteNotes = computed(() =>
  sortNotes(filteredNotes.value.filter(noteFavorite))
)

interface TreeNode {
  name: string
  path: string
  folders: Map<string, TreeNode>
  notes: Note[]
}
const emptyNode = (name: string, path: string): TreeNode => ({
  name,
  path,
  folders: new Map(),
  notes: []
})

function buildTree(list: Note[]): TreeNode {
  const root = emptyNode('', '')
  for (const n of list) {
    let cur = root
    const folder = noteFolder(n)
    if (folder) {
      let path = ''
      for (const seg of folder
        .split('/')
        .map(s => s.trim())
        .filter(Boolean)) {
        path = path ? `${path}/${seg}` : seg
        if (!cur.folders.has(seg)) cur.folders.set(seg, emptyNode(seg, path))
        cur = cur.folders.get(seg)!
      }
    }
    cur.notes.push(n)
  }
  return root
}

interface TreeRow {
  kind: 'folder' | 'note'
  depth: number
  name: string
  path?: string
  id?: string
  collapsed?: boolean
  folder?: string // containing folder path, for note rows
  favorite?: boolean
}

// Flatten the folder tree into rows honouring the collapsed set (everything is
// expanded while searching), so the template renders a flat v-for.
const treeRows = computed<TreeRow[]>(() => {
  const searching = !!searchQuery.value.trim()
  const rows: TreeRow[] = []
  const walk = (node: TreeNode, depth: number) => {
    const folders = [...node.folders.values()].sort((a, b) =>
      folderOrder.compare(a.path, b.path)
    )
    for (const f of folders) {
      const isCollapsed = !searching && collapsed.has(f.path)
      rows.push({
        kind: 'folder',
        depth,
        name: f.name,
        path: f.path,
        collapsed: isCollapsed
      })
      if (!isCollapsed) walk(f, depth + 1)
    }
    for (const n of sortNotes(node.notes)) {
      rows.push({
        kind: 'note',
        depth,
        name: n.title || 'Untitled',
        id: n.id,
        folder: node.path,
        favorite: noteFavorite(n)
      })
    }
  }
  walk(buildTree(filteredNotes.value), 0)
  return rows
})

const previewHtml = computed(() =>
  renderMarkdown(
    editBody.value,
    t => resolveTargetNote(t)?.id ?? null,
    t => resolveMention(t)?.kind ?? null
  )
)

const saveStatusLabel = computed(() => {
  if (saveState.value === 'error') return saveError.value || 'Save failed'
  return { idle: '', saving: 'Saving…', saved: 'Saved' }[saveState.value] || ''
})

function toggleFolder(path: string) {
  if (collapsed.has(path)) collapsed.delete(path)
  else collapsed.add(path)
}

// ----- folder rename / drag & drop / ordering -----

const renamingFolder = ref<string | null>(null) // full path being renamed
const renameValue = ref('') // last segment only
const draggingNoteId = ref<string | null>(null)
const draggingFolderPath = ref<string | null>(null)
const dragOverFolder = ref<string | null>(null)

const parentOf = (p: string) =>
  p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : ''

// Every folder path present in the tree (including intermediate segments).
const allFolderPaths = computed(() => {
  const s = new Set<string>()
  for (const n of notes.value) {
    let path = ''
    for (const seg of noteFolder(n)
      .split('/')
      .map(x => x.trim())
      .filter(Boolean)) {
      path = path ? `${path}/${seg}` : seg
      s.add(path)
    }
  }
  return [...s]
})

const folderOptions = computed(() =>
  [...allFolderPaths.value].sort((a, b) =>
    a.toLowerCase().localeCompare(b.toLowerCase())
  )
)

function onFolderInput(v: string) {
  editFolder.value = v
  scheduleSave()
}

function onFolderSelect() {
  void flushSave()
}

// Moves/renames rewrite [[folder/title]] wikilinks server-side; reload so we
// don't hold (and later save back) stale bodies.
async function reloadNotes() {
  try {
    notes.value = await apiList()
  } catch {
    // keep what we have
  }
}

async function startRenameFolder(path: string) {
  renamingFolder.value = path
  renameValue.value = path.split('/').pop() || ''
  await nextTick()
  const el = document.querySelector(
    '.nt-folder-rename'
  ) as HTMLInputElement | null
  el?.focus()
  el?.select()
}

async function commitRenameFolder() {
  const path = renamingFolder.value
  const seg = renameValue.value.trim()
  renamingFolder.value = null
  if (!path || !seg || seg.includes('/')) return
  const parent = parentOf(path)
  const newPath = parent ? `${parent}/${seg}` : seg
  if (newPath === path) return
  await flushSave()
  const affected = notes.value.filter(n => {
    const f = noteFolder(n)
    return f === path || f.startsWith(path + '/')
  })
  try {
    for (const n of affected) {
      await apiUpdate(n.id, {
        title: n.title || '',
        folder: newPath + noteFolder(n).slice(path.length),
        body: noteBody(n)
      })
    }
  } catch {
    // partial rename: the reload below shows the actual state
  }
  folderOrder.rename(path, newPath)
  await reloadNotes()
}

function onNoteDragStart(id: string, e: DragEvent) {
  draggingNoteId.value = id
  e.dataTransfer?.setData('text/plain', id)
  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move'
}

function onFolderDragStart(path: string, e: DragEvent) {
  draggingFolderPath.value = path
  e.dataTransfer?.setData('text/plain', path)
  if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move'
}

async function moveNoteToFolder(id: string, folder: string) {
  const n = notes.value.find(x => x.id === id)
  if (!n || noteFolder(n) === folder) return
  await flushSave()
  try {
    await apiUpdate(n.id, { title: n.title || '', folder, body: noteBody(n) })
  } catch {
    return
  }
  await reloadNotes()
}

// Reordering only makes sense between siblings; dropping a root-level folder
// on the tree background sends it to the end.
function reorderFolder(from: string, target: string) {
  if (from === target) return
  const parent = parentOf(from)
  if (target ? parentOf(target) !== parent : parent !== '') return
  const seq = allFolderPaths.value
    .filter(p => parentOf(p) === parent && p !== from)
    .sort(folderOrder.compare)
  const idx = target ? seq.indexOf(target) : seq.length
  seq.splice(idx === -1 ? seq.length : idx, 0, from)
  folderOrder.setGroup(seq)
}

function onTreeDrop(target: string) {
  dragOverFolder.value = null
  if (draggingFolderPath.value) {
    const from = draggingFolderPath.value
    draggingFolderPath.value = null
    reorderFolder(from, target)
    return
  }
  if (draggingNoteId.value) {
    const id = draggingNoteId.value
    draggingNoteId.value = null
    void moveNoteToFolder(id, target)
  }
}

// ----- save (debounced + serialized) -----

let saveTimer: ReturnType<typeof setTimeout> | undefined
let saveChain: Promise<void> = Promise.resolve()

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    saveTimer = undefined
    void enqueueSave()
  }, 600)
}
function enqueueSave(): Promise<void> {
  saveChain = saveChain.then(() => save())
  return saveChain
}
function flushSave(): Promise<void> {
  if (!saveTimer) return saveChain
  clearTimeout(saveTimer)
  saveTimer = undefined
  return enqueueSave()
}

async function save() {
  const note = selected.value
  if (!note) return
  const attrs = {
    title: editTitle.value.trim(),
    folder: editFolder.value.trim(),
    body: editBody.value
  }
  if (!attrs.title) return

  const renamed =
    attrs.title !== (note.title || '') || attrs.folder !== noteFolder(note)
  saveState.value = 'saving'
  try {
    const updated = await apiUpdate(note.id, attrs)
    if (renamed) {
      // A rename rewrites [[wikilinks]] in referencing notes server-side; reload
      // so we don't hold (and later save back) stale bodies.
      notes.value = await apiList()
    } else {
      notes.value = notes.value.map(n => (n.id === updated.id ? updated : n))
    }
    saveState.value = 'saved'
    saveError.value = ''
  } catch (e) {
    saveState.value = 'error'
    saveError.value = e instanceof Error ? e.message : 'Save failed'
  }
}

function onEditInput() {
  scheduleSave()
}

// ----- selection / CRUD -----

function syncEditorFrom(note: Note | null) {
  editTitle.value = note?.title || ''
  editFolder.value = note ? noteFolder(note) : ''
  editBody.value = note ? noteBody(note) : ''
}

// A note is addressable: `/apps/notes?selected=<id>` is the URL the app pushes
// on selection, so every place that points at a note is a real anchor with an
// href. Middle-click and "open in a new tab" then work like any link, while a
// plain left click stays in-app (no reload).
function noteHref(id: string): string {
  return `/apps/notes?selected=${encodeURIComponent(id)}`
}

// True when the browser should handle the click itself (new tab or window).
function opensNewTab(e: MouseEvent): boolean {
  // `> 0` and not `!== 0`: a synthetic click may leave `button` undefined.
  return e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button > 0
}

function onNoteLinkClick(id: string, e: MouseEvent) {
  if (opensNewTab(e)) return
  e.preventDefault()
  void selectNote(id)
}

async function selectNote(id: string, opts: { push?: boolean } = {}) {
  await flushSave()
  saveState.value = 'idle'
  saveError.value = ''
  selectedId.value = id
  backlinks.value = []
  hideAutocomplete()
  syncEditorFrom(selected.value)
  if (opts.push !== false) {
    history.pushState(null, '', `/apps/notes?selected=${id}`)
  }
  try {
    const bl = await apiBacklinks(id)
    if (selectedId.value === id) backlinks.value = bl
  } catch {
    // ignore
  }
}

function onPopState() {
  const id = new URLSearchParams(window.location.search).get('selected')
  if (id) void selectNote(id, { push: false })
  else {
    void flushSave()
    selectedId.value = null
    syncEditorFrom(null)
  }
}

function uniqueTitle(base: string): string {
  const existing = new Set(notes.value.map(n => (n.title || '').toLowerCase()))
  if (!existing.has(base.toLowerCase())) return base
  let i = 2
  while (existing.has(`${base} ${i}`.toLowerCase())) i++
  return `${base} ${i}`
}

async function createNote(folder = '') {
  try {
    const created = await apiCreate({
      title: uniqueTitle('Untitled'),
      folder,
      body: ''
    })
    notes.value.push(created)
    selectedId.value = created.id
    backlinks.value = []
    saveState.value = 'idle'
    saveError.value = ''
    viewMode.value = 'split'
    syncEditorFrom(created)
    history.pushState(null, '', `/apps/notes?selected=${created.id}`)
    await nextTick()
    const titleEl = document.querySelector(
      '.nt-title'
    ) as HTMLInputElement | null
    titleEl?.focus()
    titleEl?.select()
  } catch {
    // ignore
  }
}

async function createNamedNote(title: string) {
  try {
    const created = await apiCreate({ title, folder: '', body: '' })
    notes.value.push(created)
    await selectNote(created.id)
  } catch {
    // ignore
  }
}

// Open (or create) today's journal note: Journal/YYYY-MM-DD in the user's tz.
async function openTodayNote() {
  const title = todayInUserTz()
  const existing = notes.value.find(
    n => (n.title || '') === title && noteFolder(n) === 'Journal'
  )
  if (existing) {
    void selectNote(existing.id)
    return
  }
  try {
    const created = await apiCreate({ title, folder: 'Journal', body: '' })
    notes.value.push(created)
    await selectNote(created.id)
  } catch {
    // ignore
  }
}

async function toggleFavorite() {
  const note = selected.value
  if (!note) return
  // Flush first so a pending rename is not applied out of order.
  await flushSave()
  try {
    const updated = await apiUpdate(note.id, { favorite: !noteFavorite(note) })
    notes.value = notes.value.map(n => (n.id === updated.id ? updated : n))
  } catch {
    // ignore
  }
}

async function deleteSelected() {
  const note = selected.value
  if (!note) return
  const ok = await ctx.confirm.ask({
    title: 'Delete note',
    message: `Delete "${note.title || 'Untitled'}"? This cannot be undone.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  try {
    await apiDelete(note.id)
    notes.value = notes.value.filter(n => n.id !== note.id)
    if (selectedId.value === note.id) {
      selectedId.value = null
      backlinks.value = []
    }
  } catch {
    // ignore
  }
}

// ----- preview clicks (wikilinks / mentions) -----

function onPreviewClick(e: MouseEvent) {
  const target = e.target as HTMLElement
  const mention = target.closest('.nt-mention') as HTMLElement | null
  if (mention) {
    e.preventDefault()
    const item = resolveMention(mention.dataset.target || '')
    if (item?.kind === 'contact') ctx.navigate(`/contacts/${item.id}`)
    else if (item?.kind === 'event') ctx.navigate('/apps/calendar')
    return
  }
  const link = target.closest('.nt-wikilink') as HTMLElement | null
  if (!link) return
  // A resolved wikilink carries an href: let the browser open the new tab.
  if (opensNewTab(e) && link.getAttribute('href')) return
  e.preventDefault()
  const t = link.dataset.target || ''
  const existing = resolveTargetNote(t)
  if (existing) void selectNote(existing.id)
  else void createNamedNote(t)
}

// ----- wikilink / mention autocomplete -----

interface AcItem {
  label: string
  icon: string
  text: string // full replacement for the acReplaceLen chars before the caret
}

const acItems = ref<AcItem[]>([])
const acIndex = ref(0)
const acVisible = ref(false)
const acStyle = ref<Record<string, string>>({})
let acReplaceLen = 0

function hideAutocomplete() {
  acVisible.value = false
  acItems.value = []
}

function mentionItems(query: string, close: boolean): AcItem[] {
  const q = query.toLowerCase()
  return mentionables.value
    .filter(m => m.name.toLowerCase().includes(q))
    .slice(0, 8)
    .map(m => ({
      label: m.name,
      icon: m.kind === 'event' ? '📅' : '👤',
      text: close ? `${m.name}]]` : `@[[${m.name}]]`
    }))
}

// Viewport coordinates of the caret in a textarea, via a hidden mirror div.
function caretViewportPosition(ta: HTMLTextAreaElement): {
  left: number
  top: number
  lineHeight: number
} {
  const cs = getComputedStyle(ta)
  const mirror = document.createElement('div')
  for (const prop of [
    'fontFamily',
    'fontSize',
    'fontWeight',
    'letterSpacing',
    'lineHeight',
    'textTransform',
    'wordSpacing',
    'paddingTop',
    'paddingRight',
    'paddingBottom',
    'paddingLeft',
    'borderWidth',
    'boxSizing',
    'tabSize'
  ] as const) {
    mirror.style[prop as never] = cs[prop as never]
  }
  mirror.style.position = 'absolute'
  mirror.style.visibility = 'hidden'
  mirror.style.whiteSpace = 'pre-wrap'
  mirror.style.wordWrap = 'break-word'
  mirror.style.overflow = 'hidden'
  mirror.style.width = `${ta.clientWidth}px`

  mirror.textContent = ta.value.slice(0, ta.selectionStart)
  const marker = document.createElement('span')
  marker.textContent = '​'
  mirror.appendChild(marker)
  document.body.appendChild(mirror)

  const lineHeight = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2
  const rect = ta.getBoundingClientRect()
  const left = rect.left + marker.offsetLeft - ta.scrollLeft
  const top = rect.top + marker.offsetTop - ta.scrollTop
  mirror.remove()
  return { left, top, lineHeight }
}

async function updateAutocomplete() {
  const ta = bodyRef.value
  if (!ta) return
  const before = ta.value.slice(0, ta.selectionStart)

  // Three triggers: `[[` completes notes, `@[[` and bare `@` complete mentions.
  const wiki = before.match(/(?<!@)\[\[([^\][]*)$/)
  const openMention = wiki ? null : before.match(/@\[\[([^\][]*)$/)
  const bareMention =
    wiki || openMention
      ? null
      : before.match(/(?<![\w@])@([\p{L}\p{N} '’_-]*)$/u)

  let items: AcItem[]
  if (wiki) {
    const q = wiki[1].toLowerCase()
    acReplaceLen = wiki[1].length
    items = sortNotes(
      notes.value.filter(n => (n.title || '').toLowerCase().includes(q))
    )
      .slice(0, 8)
      .map(n => ({
        label: n.title || '',
        icon: '',
        text: `${n.title || ''}]]`
      }))
  } else if (openMention) {
    acReplaceLen = openMention[1].length
    items = mentionItems(openMention[1], true)
  } else if (bareMention) {
    acReplaceLen = bareMention[1].length + 1
    items = mentionItems(bareMention[1], false)
  } else {
    hideAutocomplete()
    return
  }

  if (!items.length) {
    hideAutocomplete()
    return
  }

  acItems.value = items
  acIndex.value = 0
  acVisible.value = true

  // Anchor at the caret, clamped to the viewport; flip above the line if there
  // is no room below. Measure after the popup renders.
  const caret = caretViewportPosition(ta)
  await nextTick()
  const pop = document.querySelector('.nt-ac') as HTMLElement | null
  const popW = pop?.offsetWidth ?? 180
  const popH = pop?.offsetHeight ?? 0
  const left = Math.min(caret.left, window.innerWidth - popW - 8)
  let top = caret.top + caret.lineHeight
  if (top + popH > window.innerHeight - 8) top = caret.top - popH - 4
  acStyle.value = {
    left: `${Math.max(8, left)}px`,
    top: `${Math.max(8, top)}px`
  }
}

function applyCompletion(item: AcItem) {
  const ta = bodyRef.value
  if (!ta) return
  const pos = ta.selectionStart
  const before = ta.value.slice(0, pos - acReplaceLen)
  const after = ta.value.slice(pos)
  const newValue = before + item.text + after
  editBody.value = newValue
  hideAutocomplete()
  const newPos = before.length + item.text.length
  nextTick(() => {
    ta.focus()
    ta.setSelectionRange(newPos, newPos)
  })
  scheduleSave()
}

// Enter inside a list line continues the list (Shift+Enter keeps the plain newline).
function onEnterInList(e: KeyboardEvent) {
  const ta = bodyRef.value
  if (!ta || ta.selectionStart !== ta.selectionEnd) return
  const edit = continueListEdit(ta.value, ta.selectionStart)
  if (!edit) return
  e.preventDefault()
  editBody.value = edit.value
  nextTick(() => ta.setSelectionRange(edit.pos, edit.pos))
  scheduleSave()
}

function onBodyKeydown(e: KeyboardEvent) {
  if (!acVisible.value || !acItems.value.length) {
    if (
      e.key === 'Enter' &&
      !e.shiftKey &&
      !e.ctrlKey &&
      !e.metaKey &&
      !e.altKey
    ) {
      onEnterInList(e)
    }
    return
  }
  if (e.key === 'Escape') {
    hideAutocomplete()
  } else if (e.key === 'ArrowDown') {
    e.preventDefault()
    acIndex.value = (acIndex.value + 1) % acItems.value.length
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    acIndex.value =
      (acIndex.value - 1 + acItems.value.length) % acItems.value.length
  } else if (e.key === 'Enter' || e.key === 'Tab') {
    e.preventDefault()
    applyCompletion(acItems.value[acIndex.value])
  }
}

function onBodyInput() {
  onEditInput()
  updateAutocomplete()
}

function onBodyBlur() {
  // Delay so a mousedown on a popup item still registers before it closes.
  setTimeout(hideAutocomplete, 150)
}

const viewModes = ['edit', 'split', 'preview'] as const

// Re-fill the editor when the selection moves to another note. Deliberately
// not on every object identity change: a save replaces the note object with
// the server's copy, and re-filling from it would drop whatever was typed
// during the round trip and send the caret to the end of the text.
watch(selected, (note, previous) => {
  if (note && note.id !== previous?.id) syncEditorFrom(note)
})

// Remembered per device, so reopening the app lands on the last note.
watch(selectedId, id => {
  if (id) localStorage.setItem(LAST_OPEN_KEY, id)
})

// ----- bootstrap -----

onMounted(async () => {
  window.addEventListener('popstate', onPopState)
  void folderOrder.load()
  try {
    notes.value = await apiList()
    loadState.value = 'ready'
  } catch {
    loadState.value = 'error'
  }

  // URL selection wins; otherwise reopen the last note used on this device.
  const initial = new URLSearchParams(window.location.search).get('selected')
  const lastOpen = localStorage.getItem(LAST_OPEN_KEY)
  const target = [initial, lastOpen].find(
    id => id && notes.value.some(n => n.id === id)
  )
  if (target) void selectNote(target, { push: false })

  // Contacts and events feed @[[mention]] autocomplete/chips; degrade gracefully.
  try {
    const [contacts, events] = await Promise.all([
      ctx.api.entries.list({ kind: 'contact' }),
      ctx.api.entries.list({ kind: 'event' })
    ])
    const contactItems = dedupeByName(
      contacts
        .map(c => ({
          id: c.id,
          kind: 'contact' as const,
          name: mentionName(c)
        }))
        .sort((a, b) =>
          a.name.toLowerCase().localeCompare(b.name.toLowerCase())
        )
    )
    const eventItems = dedupeByName(
      events
        .slice()
        // Recent first, so recurring event titles resolve to the latest one.
        .sort((a, b) =>
          (b.occurred_at || '').localeCompare(a.occurred_at || '')
        )
        .map(e => ({
          id: e.id,
          kind: 'event' as const,
          name: (e.title || '').trim()
        }))
    )
    mentionables.value = [...contactItems, ...eventItems]
  } catch {
    // mention chips render as unresolved without this data
  }
})

onBeforeUnmount(() => {
  window.removeEventListener('popstate', onPopState)
  // Fire-and-forget: persist any pending debounced edit before teardown.
  void flushSave()
})
</script>

<template>
  <div class="nt-layout">
    <div class="nt-sidebar">
      <div class="nt-side-head">
        <input
          class="nt-search"
          type="text"
          placeholder="Search notes..."
          v-model="searchQuery"
        />
      </div>
      <div class="nt-tree" @dragover.prevent @drop.prevent="onTreeDrop('')">
        <template v-if="favoriteNotes.length">
          <div class="nt-fav-head">Favorites</div>
          <a
            v-for="n in favoriteNotes"
            :key="'fav:' + n.id"
            class="nt-note nt-note--fav"
            :class="{ 'nt-note--active': n.id === selectedId }"
            :href="noteHref(n.id)"
            @click="onNoteLinkClick(n.id, $event)"
          >
            <Star :size="11" class="nt-star" fill="currentColor" />
            <span class="nt-note-title">{{ n.title || 'Untitled' }}</span>
          </a>
        </template>
        <template v-if="treeRows.length">
          <div
            v-for="row in treeRows"
            :key="row.kind === 'folder' ? 'f:' + row.path : 'n:' + row.id"
          >
            <div
              v-if="row.kind === 'folder'"
              class="nt-folder"
              :class="{ 'nt-folder--drop': dragOverFolder === row.path }"
              :style="{ paddingLeft: row.depth * 12 + 8 + 'px' }"
              draggable="true"
              @click="toggleFolder(row.path!)"
              @dragstart="onFolderDragStart(row.path!, $event)"
              @dragend="draggingFolderPath = null"
              @dragover.prevent="dragOverFolder = row.path!"
              @dragleave="dragOverFolder = null"
              @drop.prevent.stop="onTreeDrop(row.path!)"
            >
              <span class="nt-folder-caret">{{
                row.collapsed ? '▸' : '▾'
              }}</span>
              <input
                v-if="renamingFolder === row.path"
                class="nt-folder-rename"
                v-model="renameValue"
                @click.stop
                @keyup.enter="commitRenameFolder"
                @keyup.esc="renamingFolder = null"
                @blur="commitRenameFolder"
              />
              <template v-else>
                <span class="nt-folder-name">{{ row.name }}</span>
                <button
                  class="nt-folder-edit"
                  title="Rename folder"
                  @click.stop="startRenameFolder(row.path!)"
                >
                  ✎
                </button>
              </template>
            </div>
            <a
              v-else
              class="nt-note"
              :class="{ 'nt-note--active': row.id === selectedId }"
              :style="{ paddingLeft: row.depth * 12 + 22 + 'px' }"
              :href="noteHref(row.id!)"
              draggable="true"
              @dragstart="onNoteDragStart(row.id!, $event)"
              @dragend="draggingNoteId = null"
              @dragover.prevent
              @drop.prevent.stop="onTreeDrop(row.folder ?? '')"
              @click="onNoteLinkClick(row.id!, $event)"
            >
              <Star
                v-if="row.favorite"
                :size="10"
                class="nt-star"
                fill="currentColor"
              />
              <span class="nt-note-title">{{ row.name }}</span>
            </a>
          </div>
        </template>
        <p v-else class="nt-empty">
          {{
            loadState === 'error' ? 'Failed to load notes.' : 'No notes yet.'
          }}
        </p>
      </div>
    </div>

    <div class="nt-main">
      <div class="nt-main-topbar">
        <span class="nt-count"
          >{{ filteredNotes.length }}
          <span class="nt-count-unit">{{
            filteredNotes.length === 1 ? 'NOTE' : 'NOTES'
          }}</span></span
        >
        <div class="nt-topbar-actions">
          <button
            class="nt-today-btn"
            title="Open today's journal note (Journal/date)"
            @click="openTodayNote"
          >
            Today
          </button>
          <button class="nt-new-btn" @click="createNote()">
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
            New note
          </button>
        </div>
      </div>
      <p v-if="loadState === 'loading'" class="nt-placeholder">
        Loading notes…
      </p>
      <p v-else-if="!selected" class="nt-placeholder">
        Select or create a note to start writing.
      </p>
      <template v-else>
        <div class="nt-toolbar">
          <div class="nt-toolbar-row">
            <input
              class="nt-title"
              v-model="editTitle"
              placeholder="Untitled"
              @input="onEditInput"
            />
            <span
              class="nt-save-status"
              :class="{ 'nt-save-status--error': saveState === 'error' }"
              :title="saveState === 'error' ? saveError : ''"
              >{{ saveStatusLabel }}</span
            >
            <button
              class="nt-fav-btn"
              :class="{ 'nt-fav-btn--active': noteFavorite(selected) }"
              :title="
                noteFavorite(selected)
                  ? 'Remove from favorites'
                  : 'Add to favorites'
              "
              @click="toggleFavorite"
            >
              <Star
                :size="15"
                :fill="noteFavorite(selected) ? 'currentColor' : 'none'"
              />
            </button>
            <button
              class="nt-delete"
              title="Delete note"
              @click="deleteSelected"
            >
              🗑
            </button>
          </div>
          <div class="nt-toolbar-row">
            <AutocompleteInput
              class="nt-folder-input"
              :model-value="editFolder"
              :options="folderOptions"
              placeholder="Folder (e.g. Projects/Servant)"
              @update:model-value="onFolderInput"
              @select="onFolderSelect"
            />
            <span class="nt-toolbar-spacer"></span>
            <span v-if="createdLabel" class="nt-created"
              >Created {{ createdLabel }}</span
            >
            <div class="nt-view-toggle">
              <button
                v-for="m in viewModes"
                :key="m"
                class="nt-vb"
                :class="{ 'nt-vb--active': viewMode === m }"
                @click="viewMode = m"
              >
                {{ m }}
              </button>
            </div>
          </div>
        </div>

        <div class="nt-panes">
          <textarea
            v-if="showEditor"
            ref="bodyRef"
            class="nt-body"
            placeholder="Write markdown… use [[wikilinks]] and #tags"
            v-model="editBody"
            @input="onBodyInput"
            @keydown="onBodyKeydown"
            @blur="onBodyBlur"
          ></textarea>
          <div
            v-if="showPreview"
            class="nt-preview"
            @click="onPreviewClick"
            v-html="previewHtml"
          ></div>
        </div>

        <div class="nt-backlinks" v-if="backlinks.length">
          <div class="nt-bl-title">Linked from</div>
          <a
            v-for="n in backlinks"
            :key="n.id"
            class="nt-bl-item"
            :href="noteHref(n.id)"
            @click="onNoteLinkClick(n.id, $event)"
            >{{ n.title || 'Untitled' }}</a
          >
        </div>
      </template>
    </div>

    <Teleport to="body">
      <div v-if="acVisible" class="nt-ac" :style="acStyle">
        <div
          v-for="(item, i) in acItems"
          :key="i"
          class="nt-ac-item"
          :class="{ 'nt-ac-item--active': i === acIndex }"
          @mousedown.prevent="applyCompletion(item)"
        >
          <template v-if="item.icon">{{ item.icon }} </template>{{ item.label }}
        </div>
      </div>
    </Teleport>
  </div>
</template>

<!-- Global (unscoped) so preview v-html content and the teleported popup are
     styled exactly as before. -->
<style>
.nt-layout {
  display: flex;
  height: calc(100vh - 4rem);
}
.nt-sidebar {
  width: 280px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
}
.nt-side-head {
  display: flex;
  gap: 0.5rem;
  padding: 0.75rem;
  border-bottom: 1px solid var(--border);
}
.nt-search {
  flex: 1;
}
.nt-main-topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1.25rem;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.nt-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  color: var(--text);
  white-space: nowrap;
}
.nt-count-unit {
  color: var(--text-muted);
  letter-spacing: 0.08em;
}
.nt-topbar-actions {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.nt-new-btn {
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
  transition:
    background 0.15s,
    border-color 0.15s,
    color 0.15s,
    transform 0.15s;
}
.nt-new-btn:hover,
.nt-new-btn:focus-visible {
  border-color: var(--primary);
  color: var(--primary);
}
.nt-new-btn:active {
  transform: scale(0.92);
}
.nt-today-btn {
  flex-shrink: 0;
  height: 32px;
  padding: 0 0.6rem;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 8px;
  cursor: pointer;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.nt-today-btn:hover,
.nt-today-btn:focus-visible {
  border-color: var(--primary);
  color: var(--primary);
}
.nt-tree {
  flex: 1;
  overflow-y: auto;
  padding: 0.375rem 0.25rem;
}
/* Folders are structure: mono uppercase labels, clearly distinct from the
   note titles they group. */
.nt-folder {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.4rem;
  margin-top: 0.4rem;
  border-radius: 6px;
  cursor: pointer;
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.76rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.nt-folder:hover {
  background: var(--bg-hover);
}
.nt-folder-caret {
  width: 0.9em;
  flex-shrink: 0;
}
.nt-folder--drop {
  background: var(--bg-hover);
  color: var(--primary);
}
.nt-folder-name {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.nt-folder-edit {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.25rem;
  font-size: 0.8rem;
  visibility: hidden;
}
.nt-folder:hover .nt-folder-edit {
  visibility: visible;
}
.nt-folder-edit:hover {
  color: var(--primary);
}
.nt-folder-rename {
  flex: 1;
  min-width: 0;
  padding: 0.3rem 0.5rem;
  font-size: 0.85rem;
  border-radius: 6px;
}
.nt-note {
  display: block;
  padding: 0.45rem 0.5rem;
  border-radius: 6px;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  font-size: 0.92rem;
  color: inherit;
  text-decoration: none;
}
.nt-fav-head {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.68rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  padding: 0.4rem 0.5rem 0.15rem;
}
.nt-note--fav {
  display: flex;
  align-items: center;
  gap: 0.4rem;
}
.nt-note--fav .nt-note-title {
  overflow: hidden;
  text-overflow: ellipsis;
}
.nt-star {
  color: #ffb454;
  flex-shrink: 0;
  vertical-align: -1px;
}
.nt-note:hover {
  background: var(--bg-hover);
}
/* Cursor row: violet rail + tint, same language as Contacts/Files */
.nt-note--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 6px 6px 0;
}
.nt-empty,
.nt-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 2.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}
.nt-main {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.nt-toolbar {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.85rem 0.75rem;
  border-bottom: 1px solid var(--border);
}
.nt-toolbar-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.nt-toolbar-spacer {
  flex: 1;
}
.nt-title {
  font-weight: 600;
  font-size: 1.2rem;
  padding: 0.5rem 0.75rem;
  flex: 1;
  min-width: 0;
}
.nt-folder-input {
  width: 220px;
  flex-shrink: 0;
  color: var(--text);
  display: block;
}
.nt-save-status {
  flex-shrink: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  color: var(--text-muted);
  max-width: 240px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.nt-save-status--error {
  color: var(--danger);
}
.nt-created {
  flex-shrink: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.nt-view-toggle {
  display: flex;
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
}
.nt-vb {
  background: transparent;
  border: none;
  color: var(--text-muted);
  padding: 0.35rem 0.6rem;
  font-size: 0.8rem;
  cursor: pointer;
  text-transform: capitalize;
}
.nt-vb:hover {
  background: var(--bg-hover);
}
.nt-vb--active {
  background: var(--primary);
  color: var(--primary-contrast);
}
.nt-fav-btn {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 8px;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
  display: flex;
  align-items: center;
}
.nt-fav-btn:hover,
.nt-fav-btn--active {
  border-color: #ffb454;
  color: #ffb454;
}
.nt-delete {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 8px;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
}
.nt-delete:hover {
  border-color: var(--danger);
  color: var(--danger);
}
.nt-panes {
  flex: 1;
  display: flex;
  min-height: 0;
}
.nt-body {
  flex: 1;
  border: none;
  border-radius: 0;
  resize: none;
  padding: 1rem 1.25rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.9rem;
  line-height: 1.6;
  background: var(--bg);
  color: var(--text);
}
.nt-body:focus {
  outline: none;
}
.nt-panes:has(.nt-body):has(.nt-preview) .nt-body {
  border-right: 1px solid var(--border);
}
.nt-preview {
  flex: 1;
  overflow-y: auto;
  padding: 1rem 1.25rem;
  line-height: 1.65;
}
.nt-preview h1,
.nt-preview h2,
.nt-preview h3 {
  margin: 0.8em 0 0.4em;
}
.nt-preview p {
  margin: 0.5em 0;
}
.nt-preview code {
  background: var(--bg-surface);
  padding: 0.1em 0.35em;
  border-radius: 4px;
  font-size: 0.85em;
}
.nt-preview pre {
  background: var(--bg-surface);
  padding: 0.75rem;
  border-radius: 8px;
  overflow-x: auto;
}
.nt-preview pre code {
  background: none;
  padding: 0;
}
.nt-preview a {
  color: var(--primary);
}
.nt-preview ul,
.nt-preview ol {
  padding-left: 1.4em;
}
.nt-preview blockquote {
  border-left: 3px solid var(--border);
  margin: 0.5em 0;
  padding-left: 0.8em;
  color: var(--text-muted);
}
.nt-wikilink {
  color: var(--primary);
  text-decoration: none;
  border-bottom: 1px solid transparent;
  cursor: pointer;
}
.nt-wikilink:hover {
  border-bottom-color: var(--primary);
}
.nt-wikilink--new {
  color: var(--danger);
}
.nt-mention {
  display: inline-block;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0 0.5em;
  font-size: 0.85em;
  color: var(--text);
  cursor: pointer;
  text-decoration: none;
}
.nt-mention:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.nt-mention--unknown {
  opacity: 0.6;
  border-style: dashed;
  cursor: default;
}
.nt-tag {
  display: inline-block;
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
  border-radius: 6px;
  padding: 0 0.4em;
  font-size: 0.85em;
}
.nt-backlinks {
  border-top: 1px solid var(--border);
  padding: 0.5rem 1.25rem;
  max-height: 30%;
  overflow-y: auto;
}
.nt-bl-title {
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
  margin-bottom: 0.4rem;
}
.nt-bl-item {
  display: inline-block;
  margin: 0 0.5rem 0.3rem 0;
  color: var(--primary);
  cursor: pointer;
  font-size: 0.9rem;
}
.nt-bl-item:hover {
  text-decoration: underline;
}
.nt-ac {
  position: fixed;
  z-index: 10000;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.25rem;
  min-width: 180px;
  max-height: 240px;
  overflow-y: auto;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
}
.nt-ac-item {
  padding: 0.35rem 0.6rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.9rem;
}
.nt-ac-item:hover,
.nt-ac-item--active {
  background: var(--bg-hover);
}
</style>
