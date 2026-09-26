<script setup lang="ts">
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch
} from 'vue'
import {
  ChevronsDownUp,
  ChevronsUpDown,
  Paperclip,
  Plus,
  Star
} from 'lucide-vue-next'

import AutocompleteInput from '../../components/AutocompleteInput.vue'

import { formatDate, todayInUserTz } from '../../lib/datetime'
import { openDialog } from '../../lib/dialog'
import { createFolderOrder } from '../folderOrder'
import { preferenceRef } from '../preference'
import { canon, continueListEdit, renderMarkdown } from './render'
import type { AppContext, Entry } from '../types'

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

const noteFolder = (note: Note) => ((note.data.folder as string) || '').trim()
const noteBody = (note: Note) => (note.data.body as string) || ''
const noteTags = (note: Note) => (note.data.tags as string[]) || []
const noteFavorite = (note: Note) => note.data.favorite === true

const noteAttachments = (note: Note) =>
  (note.data.attachments as string[] | undefined) ?? []
const fullPath = (folder: string, title: string) =>
  folder ? `${folder}/${title}` : title

// A note is reachable as `[[title]]` or `[[folder/title]]`.
function noteKeys(note: Note): string[] {
  const title = note.title || ''
  return [canon(title), canon(fullPath(noteFolder(note), title))]
}

// vcard contact titles look like "Name - org - email" (pre-July 2026 entries
// used " — "); prefer the display name.
function mentionName(entry: Entry): string {
  return (
    (entry.data.display_name as string) ||
    (entry.title || '').split(/ - | — /)[0] ||
    ''
  ).trim()
}

function dedupeByName(list: Mentionable[]): Mentionable[] {
  const seen = new Set<string>()
  return list.filter(mention => {
    const key = canon(mention.name)
    if (!mention.name || seen.has(key)) return false
    seen.add(key)
    return true
  })
}

// ----- reactive state -----

const lastOpen = preferenceRef<string | null>(ctx, 'notes.lastOpen', null)

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
  () => notes.value.find(note => note.id === selectedId.value) || null
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
  const key = canon(target)
  return notes.value.find(note => noteKeys(note).includes(key)) || null
}
function resolveMention(target: string): Mentionable | null {
  const key = canon(target)
  return mentionables.value.find(mention => canon(mention.name) === key) || null
}

const filteredNotes = computed(() => {
  if (!searchQuery.value.trim()) return notes.value
  const needle = searchQuery.value.toLowerCase()
  return notes.value.filter(note =>
    [
      note.title || '',
      noteFolder(note),
      noteBody(note),
      noteTags(note).join(' ')
    ]
      .join(' ')
      .toLowerCase()
      .includes(needle)
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
  for (const note of list) {
    let cur = root
    const folder = noteFolder(note)
    if (folder) {
      let path = ''
      for (const seg of folder
        .split('/')
        .map(segment => segment.trim())
        .filter(Boolean)) {
        path = path ? `${path}/${seg}` : seg
        if (!cur.folders.has(seg)) cur.folders.set(seg, emptyNode(seg, path))
        cur = cur.folders.get(seg)!
      }
    }
    cur.notes.push(note)
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
    for (const note of sortNotes(node.notes)) {
      rows.push({
        kind: 'note',
        depth,
        name: note.title || 'Untitled',
        id: note.id,
        folder: node.path,
        favorite: noteFavorite(note)
      })
    }
  }
  walk(buildTree(filteredNotes.value), 0)
  return rows
})

const previewHtml = computed(() =>
  renderMarkdown(
    editBody.value,
    target => resolveTargetNote(target)?.id ?? null,
    target => resolveMention(target)?.kind ?? null
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

// Opens the folder first so the new note shows up under it in the tree.
function createNoteIn(path: string) {
  collapsed.delete(path)
  void createNote(path)
}

// Every folder path present in the tree (including intermediate segments).
const allFolderPaths = computed(() => {
  const paths = new Set<string>()
  for (const note of notes.value) {
    let path = ''
    for (const seg of noteFolder(note)
      .split('/')
      .map(segment => segment.trim())
      .filter(Boolean)) {
      path = path ? `${path}/${seg}` : seg
      paths.add(path)
    }
  }
  return [...paths]
})

// One button for the whole tree: collapse everything, unless everything is
// already collapsed, in which case expand it all back.
const allCollapsed = computed(
  () =>
    allFolderPaths.value.length > 0 &&
    allFolderPaths.value.every(path => collapsed.has(path))
)

function toggleAllFolders() {
  if (allCollapsed.value) {
    collapsed.clear()
  } else {
    for (const path of allFolderPaths.value) collapsed.add(path)
  }
}

// ----- folder rename / drag & drop / ordering -----

const renamingFolder = ref<string | null>(null) // full path being renamed
const renameValue = ref('') // last segment only
const draggingNoteId = ref<string | null>(null)
const draggingFolderPath = ref<string | null>(null)
const dragOverFolder = ref<string | null>(null)

const parentOf = (p: string) =>
  p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : ''

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
  const affected = notes.value.filter(note => {
    const f = noteFolder(note)
    return f === path || f.startsWith(path + '/')
  })
  try {
    for (const note of affected) {
      await apiUpdate(note.id, {
        title: note.title || '',
        folder: newPath + noteFolder(note).slice(path.length),
        body: noteBody(note)
      })
    }
  } catch {
    // partial rename: the reload below shows the actual state
  }
  folderOrder.rename(path, newPath)
  await reloadNotes()
}

function onNoteDragStart(id: string, event: DragEvent) {
  draggingNoteId.value = id
  event.dataTransfer?.setData('text/plain', id)
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
}

function onFolderDragStart(path: string, event: DragEvent) {
  draggingFolderPath.value = path
  event.dataTransfer?.setData('text/plain', path)
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
}

async function moveNoteToFolder(id: string, folder: string) {
  const note = notes.value.find(candidate => candidate.id === id)
  if (!note || noteFolder(note) === folder) return
  await flushSave()
  try {
    await apiUpdate(note.id, {
      title: note.title || '',
      folder,
      body: noteBody(note)
    })
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
    .filter(path => parentOf(path) === parent && path !== from)
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
      notes.value = notes.value.map(note =>
        note.id === updated.id ? updated : note
      )
    }
    saveState.value = 'saved'
    saveError.value = ''
  } catch (err) {
    saveState.value = 'error'
    saveError.value = err instanceof Error ? err.message : 'Save failed'
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
function opensNewTab(event: MouseEvent): boolean {
  // `> 0` and not `!== 0`: a synthetic click may leave `button` undefined.
  return (
    event.metaKey ||
    event.ctrlKey ||
    event.shiftKey ||
    event.altKey ||
    event.button > 0
  )
}

function onNoteLinkClick(id: string, event: MouseEvent) {
  if (opensNewTab(event)) return
  event.preventDefault()
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
  const existing = new Set(
    notes.value.map(note => (note.title || '').toLowerCase())
  )
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
    note => (note.title || '') === title && noteFolder(note) === 'Journal'
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
    notes.value = notes.value.map(note =>
      note.id === updated.id ? updated : note
    )
  } catch {
    // ignore
  }
}

// ----- attachments (Files app entries linked from the note) -----

// Loaded on demand: when a note with attachments is shown (to resolve ids
// into filenames) or when the picker opens. Folders are not attachable.
const fileEntries = ref<Entry[]>([])
const filesLoaded = ref(false)
const attachOpen = ref(false)
const attachQuery = ref('')

const fileName = (file: Entry) =>
  (file.data.filename as string) || file.title || 'unnamed'

async function ensureFiles() {
  if (filesLoaded.value) return
  try {
    const entries = await ctx.api.entries.list({ kind: 'file' })
    fileEntries.value = entries.filter(entry => entry.data.is_folder !== true)
    filesLoaded.value = true
  } catch {
    // chips fall back to "missing file"; the picker shows its empty state
  }
}

const attachedFiles = computed(() => {
  const note = selected.value
  if (!note) return []
  const byId = new Map(fileEntries.value.map(entry => [entry.id, entry]))
  return noteAttachments(note).map(id => {
    const file = byId.get(id)
    return {
      id,
      name: file ? fileName(file) : 'missing file',
      path: file ? (file.data.path as string) || '' : '',
      missing: !file
    }
  })
})

const attachOptions = computed(() => {
  const note = selected.value
  if (!note) return []
  const attached = new Set(noteAttachments(note))
  const needle = attachQuery.value.trim().toLowerCase()
  return fileEntries.value
    .filter(file => !attached.has(file.id))
    .filter(file => !needle || fileName(file).toLowerCase().includes(needle))
    .sort((a, b) => fileName(a).localeCompare(fileName(b)))
    .slice(0, 50)
})

function openAttachPicker() {
  attachQuery.value = ''
  attachOpen.value = true
  void ensureFiles()
}

async function setAttachments(note: Note, ids: string[]) {
  // Flush first so a pending rename is not applied out of order.
  await flushSave()
  try {
    const updated = await apiUpdate(note.id, { attachments: ids })
    notes.value = notes.value.map(item =>
      item.id === updated.id ? updated : item
    )
  } catch {
    // the chips keep showing the stored list
  }
}

async function attachFile(file: Entry) {
  const note = selected.value
  if (!note) return
  attachOpen.value = false
  await setAttachments(note, [...noteAttachments(note), file.id])
}

async function detachFile(id: string) {
  const note = selected.value
  if (!note) return
  await setAttachments(
    note,
    noteAttachments(note).filter(item => item !== id)
  )
}

// Resolve ids into names as soon as an annotated note is displayed.
watch(selected, note => {
  if (note && noteAttachments(note).length) void ensureFiles()
})

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
    notes.value = notes.value.filter(candidate => candidate.id !== note.id)
    if (selectedId.value === note.id) {
      selectedId.value = null
      backlinks.value = []
    }
  } catch {
    // ignore
  }
}

// ----- preview clicks (wikilinks / mentions) -----

function onPreviewClick(event: MouseEvent) {
  const target = event.target as HTMLElement
  const mention = target.closest('.nt-mention') as HTMLElement | null
  if (mention) {
    event.preventDefault()
    const item = resolveMention(mention.dataset.target || '')
    if (item?.kind === 'contact') ctx.navigate(`/contacts/${item.id}`)
    else if (item?.kind === 'event') ctx.navigate('/apps/calendar')
    return
  }
  const link = target.closest('.nt-wikilink') as HTMLElement | null
  if (!link) return
  // A resolved wikilink carries an href: let the browser open the new tab.
  if (opensNewTab(event) && link.getAttribute('href')) return
  event.preventDefault()
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
  const needle = query.toLowerCase()
  return mentionables.value
    .filter(mention => mention.name.toLowerCase().includes(needle))
    .slice(0, 8)
    .map(mention => ({
      label: mention.name,
      icon: mention.kind === 'event' ? '📅' : '👤',
      text: close ? `${mention.name}]]` : `@[[${mention.name}]]`
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
    const needle = wiki[1].toLowerCase()
    acReplaceLen = wiki[1].length
    items = sortNotes(
      notes.value.filter(note =>
        (note.title || '').toLowerCase().includes(needle)
      )
    )
      .slice(0, 8)
      .map(note => ({
        label: note.title || '',
        icon: '',
        text: `${note.title || ''}]]`
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
function onEnterInList(event: KeyboardEvent) {
  const ta = bodyRef.value
  if (!ta || ta.selectionStart !== ta.selectionEnd) return
  const edit = continueListEdit(ta.value, ta.selectionStart)
  if (!edit) return
  event.preventDefault()
  editBody.value = edit.value
  nextTick(() => ta.setSelectionRange(edit.pos, edit.pos))
  scheduleSave()
}

function onBodyKeydown(event: KeyboardEvent) {
  if (!acVisible.value || !acItems.value.length) {
    if (
      event.key === 'Enter' &&
      !event.shiftKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey
    ) {
      onEnterInList(event)
    }
    return
  }
  if (event.key === 'Escape') {
    hideAutocomplete()
  } else if (event.key === 'ArrowDown') {
    event.preventDefault()
    acIndex.value = (acIndex.value + 1) % acItems.value.length
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    acIndex.value =
      (acIndex.value - 1 + acItems.value.length) % acItems.value.length
  } else if (event.key === 'Enter' || event.key === 'Tab') {
    event.preventDefault()
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

// Remembered on the account, so reopening the app lands on the last note.
watch(selectedId, id => {
  if (id) lastOpen.value = id
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

  // URL selection wins; otherwise reopen the last note used.
  const initial = new URLSearchParams(window.location.search).get('selected')
  const target = [initial, lastOpen.value].find(
    id => id && notes.value.some(note => note.id === id)
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
        .map(contact => ({
          id: contact.id,
          kind: 'contact' as const,
          name: mentionName(contact)
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
        .map(entry => ({
          id: entry.id,
          kind: 'event' as const,
          name: (entry.title || '').trim()
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
          v-model="searchQuery"
          v-autofocus
          class="nt-search"
          type="text"
          placeholder="Search notes..."
          aria-label="Search notes"
        />
        <button
          v-if="allFolderPaths.length"
          class="nt-tree-toggle"
          :title="allCollapsed ? 'Expand all folders' : 'Collapse all folders'"
          :aria-label="
            allCollapsed ? 'Expand all folders' : 'Collapse all folders'
          "
          @click="toggleAllFolders"
        >
          <ChevronsUpDown v-if="allCollapsed" :size="14" />
          <ChevronsDownUp v-else :size="14" />
        </button>
      </div>
      <div class="nt-tree" @dragover.prevent @drop.prevent="onTreeDrop('')">
        <template v-if="favoriteNotes.length">
          <div class="nt-fav-head">Favorites</div>
          <a
            v-for="note in favoriteNotes"
            :key="'fav:' + note.id"
            class="nt-note nt-note--fav"
            :class="{ 'nt-note--active': note.id === selectedId }"
            :href="noteHref(note.id)"
            @click="onNoteLinkClick(note.id, $event)"
          >
            <Star :size="11" class="nt-star" fill="currentColor" />
            <span class="nt-note-title">{{ note.title || 'Untitled' }}</span>
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
                <button
                  class="nt-folder-edit nt-folder-add"
                  title="New note in this folder"
                  :aria-label="`New note in ${row.name}`"
                  @click.stop="createNoteIn(row.path!)"
                >
                  <Plus :size="14" />
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
            <button
              class="nt-attach-btn"
              title="Attach a file"
              aria-label="Attach a file"
              @click="openAttachPicker"
            >
              <Paperclip :size="14" />
            </button>
            <span class="nt-toolbar-spacer"></span>
            <span v-if="createdLabel" class="nt-created"
              >Created {{ createdLabel }}</span
            >
            <div class="nt-view-toggle">
              <button
                v-for="mode in viewModes"
                :key="mode"
                class="nt-vb"
                :class="{ 'nt-vb--active': viewMode === mode }"
                @click="viewMode = mode"
              >
                {{ mode }}
              </button>
            </div>
          </div>
        </div>

        <div v-if="attachedFiles.length" class="nt-attachments">
          <span
            v-for="file in attachedFiles"
            :key="file.id"
            class="nt-attachment"
            :class="{ 'nt-attachment--missing': file.missing }"
          >
            <Paperclip :size="12" class="nt-attachment-icon" />
            <a
              v-if="!file.missing"
              class="nt-attachment-name"
              :href="file.path"
              target="_blank"
              rel="noopener"
              >{{ file.name }}</a
            >
            <span v-else class="nt-attachment-name">{{ file.name }}</span>
            <button
              class="nt-attachment-remove"
              :aria-label="`Detach ${file.name}`"
              @click="detachFile(file.id)"
            >
              ×
            </button>
          </span>
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
            v-for="note in backlinks"
            :key="note.id"
            class="nt-bl-item"
            :href="noteHref(note.id)"
            @click="onNoteLinkClick(note.id, $event)"
            >{{ note.title || 'Untitled' }}</a
          >
        </div>
      </template>
    </div>

    <Teleport to="body">
      <div v-if="acVisible" class="nt-ac" :style="acStyle">
        <div
          v-for="(item, index) in acItems"
          :key="index"
          class="nt-ac-item"
          :class="{ 'nt-ac-item--active': index === acIndex }"
          @mousedown.prevent="applyCompletion(item)"
        >
          <template v-if="item.icon">{{ item.icon }} </template>{{ item.label }}
        </div>
      </div>
    </Teleport>

    <Teleport to="body">
      <dialog
        v-if="attachOpen"
        :ref="openDialog"
        class="modal-dialog"
        aria-labelledby="nt-attach-title"
        @click.self="attachOpen = false"
        @cancel="attachOpen = false"
      >
        <div class="nt-attach-modal">
          <div id="nt-attach-title" class="nt-attach-header">Attach a file</div>
          <input
            v-model="attachQuery"
            class="nt-attach-search"
            type="text"
            placeholder="Search files..."
            aria-label="Search files"
            autofocus
          />
          <p v-if="!attachOptions.length" class="nt-attach-empty">
            {{
              filesLoaded
                ? 'No matching file. Files come from the Files app.'
                : 'Loading files…'
            }}
          </p>
          <ul v-else class="nt-attach-list">
            <li v-for="file in attachOptions" :key="file.id">
              <button class="nt-attach-option" @click="attachFile(file)">
                {{ fileName(file) }}
              </button>
            </li>
          </ul>
          <div class="nt-attach-actions">
            <button class="nt-attach-cancel" @click="attachOpen = false">
              Cancel
            </button>
          </div>
        </div>
      </dialog>
    </Teleport>
  </div>
</template>

<!-- Global (unscoped) so preview v-html content and the teleported popup are
     styled exactly as before. -->
<style>
.nt-layout {
  display: flex;
  height: 100vh;
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
  min-width: 0;
}
.nt-tree-toggle {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 6px;
  padding: 0 0.45rem;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  flex-shrink: 0;
}
.nt-tree-toggle:hover {
  border-color: var(--primary);
  color: var(--primary);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
.nt-folder-add {
  display: inline-flex;
}
.nt-folder-rename {
  flex: 1;
  min-width: 0;
  padding: 0.3rem 0.5rem;
  font-size: 0.85rem;
  border-radius: 6px;
}
.nt-note {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.45rem 0.5rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.92rem;
  color: inherit;
  text-decoration: none;
}
.nt-note-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.nt-fav-head {
  font-family: var(--font-mono);
  font-size: 0.68rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  padding: 0.4rem 0.5rem 0.15rem;
}
.nt-star {
  color: #ffb454;
  flex-shrink: 0;
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
  font-family: var(--font-mono);
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
.nt-attach-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 6px;
  padding: 0 0.45rem;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  align-self: stretch;
  flex-shrink: 0;
}
.nt-attach-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.nt-save-status {
  flex-shrink: 0;
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.nt-view-toggle {
  display: flex;
  gap: 0.35rem;
}
.nt-vb {
  background: transparent;
  border: 1px solid var(--border);
  border-radius: 8px;
  color: var(--text-muted);
  padding: 0.35rem 0.6rem;
  font-size: 0.8rem;
  cursor: pointer;
  text-transform: capitalize;
}
.nt-vb:hover {
  background: var(--bg-hover);
  border-color: var(--primary);
  color: var(--text);
}
.nt-vb--active {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.nt-fav-btn,
.nt-delete {
  width: 32px;
  height: 32px;
  padding: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 8px;
  cursor: pointer;
}
.nt-fav-btn:hover,
.nt-fav-btn--active {
  border-color: #ffb454;
  color: #ffb454;
}
.nt-delete:hover {
  border-color: var(--danger);
  color: var(--danger);
}
/* ----- Attachments ----- */
.nt-attachments {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem;
  padding: 0.5rem 1.25rem;
  border-bottom: 1px solid var(--border);
}
.nt-attachment {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0.15rem 0.35rem 0.15rem 0.55rem;
  font-size: 0.78rem;
  color: var(--text-muted);
}
.nt-attachment--missing {
  border-style: dashed;
}
.nt-attachment-icon {
  flex-shrink: 0;
}
.nt-attachment-name {
  color: inherit;
  max-width: 220px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
a.nt-attachment-name:hover {
  color: var(--primary);
}
.nt-attachment-remove {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.2rem;
  font-size: 0.85rem;
  line-height: 1;
}
.nt-attachment-remove:hover {
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
  font-family: var(--font-mono);
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

/* ----- Attach-file modal ----- */
.nt-attach-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1.25rem;
  width: 100%;
  max-width: 420px;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.nt-attach-header {
  font-weight: 600;
  font-size: 1.05rem;
}
.nt-attach-empty {
  margin: 0;
  color: var(--text-muted);
  font-size: 0.85rem;
}
.nt-attach-list {
  list-style: none;
  margin: 0;
  padding: 0;
  max-height: 300px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
}
.nt-attach-option {
  width: 100%;
  text-align: left;
  border: none;
  background: transparent;
  color: var(--text);
  padding: 0.4rem 0.5rem;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.88rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.nt-attach-option:hover {
  background: var(--bg-hover);
}
.nt-attach-actions {
  display: flex;
  justify-content: flex-end;
}
.nt-attach-cancel {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
}
.nt-attach-cancel:hover {
  border-color: var(--primary);
  color: var(--primary);
}
</style>
