<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import {
  Eye,
  EyeOff,
  File,
  FileArchive,
  FileText,
  Folder,
  Image as ImageIcon,
  NotebookPen,
  Receipt,
  Video
} from 'lucide-vue-next'

import ComboBox from '../../components/ComboBox.vue'

import { formatDate } from '../../lib/datetime'
import { formatFileSize } from '../../lib/filesize'
import { safeUrl } from '../../lib/url'
import {
  batchesDone,
  enqueueUploads,
  lastCreated,
  uploadErrors,
  uploadProgress,
  uploading
} from './uploadQueue'
import type { AppContext, Entry } from '../types'

const props = defineProps<{ ctx: AppContext }>()

const allFiles = ref<Entry[]>([])
const currentFolder = ref<string | null>(null)
const selectedId = ref<string | null>(null)
const folderPath = ref<{ id: string | null; name: string }[]>([
  { id: null, name: '~' }
])
const dragover = ref(false)
const loading = ref(true)
const loadError = ref('')

function field<T = unknown>(e: Entry, k: string): T {
  return e.data[k] as T
}
const fileName = (e: Entry) => field<string>(e, 'filename') || '(unnamed)'
const isFolder = (e: Entry) => !!field(e, 'is_folder')
const fileSize = (e: Entry) => field<number>(e, 'size') || 0
const parentId = (e: Entry) => field<string>(e, 'parent_id') || null
const filePath = (e: Entry) => field<string>(e, 'path') || null
const isImage = (e: Entry) =>
  (field<string>(e, 'mime_type') || '').startsWith('image/')

// ----- virtual read-only mounts (Notes, Photos, Invoices) -----
// Other apps' entries surfaced as browse-only folders: notes keep their
// folder tree, photos group by album, invoices by provider. Loaded lazily
// on first navigation into each mount; no rename/move/delete/upload.

const VIRTUAL_ROOTS = [
  { id: 'v:notes', name: 'Notes', kind: 'note' },
  { id: 'v:photos', name: 'Photos', kind: 'photo' },
  { id: 'v:invoices', name: 'Invoices', kind: 'invoice' }
]

const VIRTUAL_ROOT_ICONS: Record<string, typeof Folder> = {
  'v:notes': NotebookPen,
  'v:photos': ImageIcon,
  'v:invoices': Receipt
}

const isVirtual = (e: Entry) => e.id.startsWith('v:')
const inVirtual = computed(() => !!currentFolder.value?.startsWith('v:'))

function vEntry(
  id: string,
  parent: string | null,
  filename: string,
  data: Record<string, unknown> = {},
  base?: Entry
): Entry {
  return {
    id,
    kind: 'file',
    source: 'virtual',
    external_id: null,
    title: filename,
    occurred_at: base?.occurred_at ?? null,
    data: { filename, parent_id: parent, ...data },
    metadata: {},
    inserted_at: base?.inserted_at ?? '',
    updated_at: base?.updated_at ?? ''
  }
}

const virtualRootEntries = VIRTUAL_ROOTS.map(r =>
  vEntry(r.id, null, r.name, { is_folder: true, v: 'root' })
)

const virtualFiles = ref<Entry[]>([])
const virtualLoaded = new Set<string>()
const virtualLoading = ref(false)

const SHOW_VIRTUAL_KEY = 'servant_files_show_virtual'
const showVirtual = ref(localStorage.getItem(SHOW_VIRTUAL_KEY) !== '0')

function toggleVirtual() {
  showVirtual.value = !showVirtual.value
  localStorage.setItem(SHOW_VIRTUAL_KEY, showVirtual.value ? '1' : '0')
  if (!showVirtual.value && inVirtual.value) setFolder(null, { push: true })
}

const allItems = computed(() => [
  ...allFiles.value,
  ...(showVirtual.value ? [...virtualRootEntries, ...virtualFiles.value] : [])
])

function vFolder(id: string, parent: string, name: string): Entry {
  return vEntry(id, parent, name, { is_folder: true, v: 'vfolder' })
}

function buildVirtual(kind: string, entries: Entry[]): Entry[] {
  const out: Entry[] = []
  const groups = new Set<string>()
  for (const entry of entries) {
    if (kind === 'note') {
      const folder = ((entry.data.folder as string) || '').trim()
      let path = ''
      for (const seg of folder.split('/').filter(Boolean)) {
        path = path ? `${path}/${seg}` : seg
        groups.add(path)
      }
      out.push(
        vEntry(
          `v:note:${entry.id}`,
          path ? `v:notes:f:${path}` : 'v:notes',
          `${entry.title || '(untitled)'}.md`,
          {
            v: 'note',
            entry_id: entry.id,
            size: ((entry.data.body as string) || '').length,
            mime_type: 'text/markdown'
          },
          entry
        )
      )
    } else if (kind === 'photo') {
      // Shot year (EXIF date, else upload date), same date source as the
      // Photos app.
      const year = (entry.occurred_at || entry.inserted_at || '').slice(0, 4)
      if (year) groups.add(year)
      out.push(
        vEntry(
          `v:photo:${entry.id}`,
          year ? `v:photos:y:${year}` : 'v:photos',
          (entry.data.filename as string) || '(unnamed)',
          {
            v: 'photo',
            size: entry.data.size,
            mime_type: entry.data.mime_type,
            path: entry.data.path
          },
          entry
        )
      )
    } else {
      const provider = ((entry.data.provider as string) || '').trim()
      if (provider) groups.add(provider)
      out.push(
        vEntry(
          `v:invoice:${entry.id}`,
          provider ? `v:invoices:p:${provider}` : 'v:invoices',
          entry.title || '(invoice)',
          { v: 'invoice', url: entry.data.url },
          entry
        )
      )
    }
  }
  for (const group of groups) {
    if (kind === 'note') {
      const segs = group.split('/')
      const parent = segs.slice(0, -1).join('/')
      out.push(
        vFolder(
          `v:notes:f:${group}`,
          parent ? `v:notes:f:${parent}` : 'v:notes',
          segs[segs.length - 1]
        )
      )
    } else if (kind === 'photo') {
      out.push(vFolder(`v:photos:y:${group}`, 'v:photos', group))
    } else {
      out.push(vFolder(`v:invoices:p:${group}`, 'v:invoices', group))
    }
  }
  return out
}

const virtualKindOf = (folderId: string) =>
  VIRTUAL_ROOTS.find(
    root => folderId === root.id || folderId.startsWith(root.id + ':')
  )?.kind

// ponytail: loaded once per app mount, no live refresh; search only covers
// mounts already visited
async function loadVirtual(folderId: string) {
  const kind = virtualKindOf(folderId)
  if (!kind || virtualLoaded.has(kind)) return
  virtualLoaded.add(kind)
  virtualLoading.value = true
  try {
    const entries = await props.ctx.api.entries.list({ kind })
    virtualFiles.value = [...virtualFiles.value, ...buildVirtual(kind, entries)]
    // Rebuild the breadcrumb if we deep-linked into this mount before it loaded.
    if (currentFolder.value && virtualKindOf(currentFolder.value) === kind) {
      setFolder(currentFolder.value)
    }
  } catch {
    virtualLoaded.delete(kind)
  } finally {
    virtualLoading.value = false
  }
}

// Invoice URLs are scraped verbatim from provider portals, so a hostile/MITM'd
// portal could inject a javascript: URI: filter through safeUrl before any href.
const invoiceUrl = (e: Entry) =>
  field<string>(e, 'v') === 'invoice'
    ? safeUrl(field<string>(e, 'url') || '')
    : null

function openVirtualFile(file: Entry) {
  const kind = field<string>(file, 'v')
  if (kind === 'note') {
    props.ctx.navigate(
      `/apps/notes?selected=${field<string>(file, 'entry_id')}`
    )
  } else if (kind === 'photo' && filePath(file)) {
    window.open(filePath(file)!, '_blank')
  } else if (kind === 'invoice') {
    const url = safeUrl(field<string>(file, 'url') || '')
    if (url) window.open(url, '_blank', 'noopener')
  }
}

function fileIcon(e: Entry): typeof Folder {
  const rootIcon = VIRTUAL_ROOT_ICONS[e.id]
  if (rootIcon) return rootIcon
  if (isFolder(e)) return Folder
  if (field<string>(e, 'v') === 'invoice') return Receipt
  const mime = field<string>(e, 'mime_type') || ''
  if (mime.startsWith('image/')) return ImageIcon
  if (mime.startsWith('video/')) return Video
  if (mime === 'application/pdf' || mime.startsWith('text/')) return FileText
  if (mime.includes('zip')) return FileArchive
  return File
}

const currentItems = computed(() =>
  allItems.value
    .filter(file => parentId(file) === currentFolder.value)
    .sort((a, b) => {
      const af = isFolder(a) ? 0 : 1
      const bf = isFolder(b) ? 0 : 1
      if (af !== bf) return af - bf
      return fileName(a).toLowerCase().localeCompare(fileName(b).toLowerCase())
    })
)

// ----- search + type filter -----

const searchQuery = ref('')
const typeFilter = ref('')

const TYPE_FILTER_OPTIONS = [
  { value: '', label: 'All types' },
  { value: 'folder', label: 'Folders' },
  { value: 'image', label: 'Images' },
  { value: 'video', label: 'Videos' },
  { value: 'doc', label: 'Documents' },
  { value: 'archive', label: 'Archives' },
  { value: 'other', label: 'Other' }
]

function matchesType(e: Entry): boolean {
  const mime = field<string>(e, 'mime_type') || ''
  switch (typeFilter.value) {
    case '':
      return true
    case 'folder':
      return isFolder(e)
    case 'image':
      return mime.startsWith('image/')
    case 'video':
      return mime.startsWith('video/')
    case 'doc':
      return mime === 'application/pdf' || mime.startsWith('text/')
    case 'archive':
      return mime.includes('zip')
    default:
      return (
        !isFolder(e) &&
        !mime.startsWith('image/') &&
        !mime.startsWith('video/') &&
        mime !== 'application/pdf' &&
        !mime.startsWith('text/') &&
        !mime.includes('zip')
      )
  }
}

// ----- folder paths (for search results and history restore) -----

const byId = computed(
  () => new Map(allItems.value.map(file => [file.id, file]))
)

// Ancestor chain of a folder id, root first. The guard caps a corrupt
// parent_id cycle.
function chainTo(id: string | null): Entry[] {
  const chain: Entry[] = []
  let cur = id ? byId.value.get(id) : undefined
  let guard = 0
  while (cur && guard++ < 50) {
    chain.unshift(cur)
    const pid = parentId(cur)
    cur = pid ? byId.value.get(pid) : undefined
  }
  return chain
}

function folderPathOf(e: Entry): string {
  const parts = chainTo(parentId(e)).map(fileName)
  return '~/' + parts.map(p => p + '/').join('')
}

// ----- folder stats (detail panel) -----

const childrenByParent = computed(() => {
  const map = new Map<string, Entry[]>()
  for (const item of allItems.value) {
    const parent = parentId(item)
    if (!parent) continue
    const list = map.get(parent)
    if (list) list.push(item)
    else map.set(parent, [item])
  }
  return map
})

interface FolderStats {
  files: number
  folders: number
  size: number
}

// Whole subtree, not just direct children: a folder's weight is what it holds
// at any depth. `seen` caps a corrupt parent_id cycle, like chainTo's guard.
function folderStats(id: string): FolderStats {
  const stats: FolderStats = { files: 0, folders: 0, size: 0 }
  const seen = new Set<string>()
  const stack = [id]
  while (stack.length) {
    for (const child of childrenByParent.value.get(stack.pop()!) || []) {
      if (seen.has(child.id)) continue
      seen.add(child.id)
      if (isFolder(child)) {
        stats.folders++
        stack.push(child.id)
      } else {
        stats.files++
        stats.size += fileSize(child)
      }
    }
  }
  return stats
}

const selectedStats = computed(() => {
  const file = selected.value
  if (!file || !isFolder(file)) return null
  // A virtual mount only lists its children once opened: don't call it empty
  // before that.
  if (isVirtual(file) && !childrenByParent.value.has(file.id)) return null
  return folderStats(file.id)
})

const contentsLabel = computed(() => {
  const s = selectedStats.value
  if (!s) return ''
  const parts = []
  if (s.files) parts.push(`${s.files} file${s.files > 1 ? 's' : ''}`)
  if (s.folders) parts.push(`${s.folders} folder${s.folders > 1 ? 's' : ''}`)
  return parts.length ? parts.join(', ') : 'Empty'
})

// Searching looks across the whole tree (flat results, files only);
// otherwise we list the current folder.
const displayed = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (q) {
    return allItems.value
      .filter(
        file =>
          !isFolder(file) &&
          fileName(file).toLowerCase().includes(q) &&
          matchesType(file)
      )
      .sort((a, b) =>
        fileName(a).toLowerCase().localeCompare(fileName(b).toLowerCase())
      )
  }
  return currentItems.value.filter(matchesType)
})

const selected = computed(() =>
  selectedId.value
    ? allFiles.value.find(file => file.id === selectedId.value) || null
    : null
)

async function reload() {
  loadError.value = ''
  try {
    allFiles.value = await props.ctx.api.entries.list({ kind: 'file' })
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load files'
  } finally {
    loading.value = false
  }
}

// Folder navigation goes through the browser history (?folder=<id>) so
// back/forward work as expected.
function setFolder(id: string | null, opts: { push?: boolean } = {}) {
  // A virtual deep link (URL restore, back button) lands at the root when
  // the mounts are hidden.
  if (id?.startsWith('v:') && !showVirtual.value) id = null
  if (id?.startsWith('v:')) void loadVirtual(id)
  currentFolder.value = id
  folderPath.value = [
    { id: null, name: '~' },
    ...chainTo(id).map(c => ({ id: c.id as string | null, name: fileName(c) }))
  ]
  selectedId.value = null
  if (opts.push) {
    history.pushState(
      null,
      '',
      id ? `/apps/files?folder=${encodeURIComponent(id)}` : '/apps/files'
    )
  }
}

function navigateCrumb(idx: number) {
  setFolder(folderPath.value[idx].id, { push: true })
}

function openFolder(file: Entry) {
  if (isFolder(file)) {
    setFolder(file.id, { push: true })
  } else if (isVirtual(file)) {
    openVirtualFile(file)
  }
}

// Jump from a search result to its containing folder.
function goToFolderOf(e: Entry) {
  searchQuery.value = ''
  setFolder(parentId(e), { push: true })
  selectedId.value = e.id
}

function onPopState() {
  setFolder(new URLSearchParams(window.location.search).get('folder'))
}

// No naming dialog: the folder is created with a placeholder name and its
// row goes straight into inline rename. Leaving the name empty (or Esc)
// deletes the just-created entry.
async function newFolder() {
  const created = await props.ctx.api.entries.create({
    kind: 'file',
    source: 'files_app',
    title: 'New folder',
    data: {
      filename: 'New folder',
      is_folder: true,
      parent_id: currentFolder.value
    }
  })
  await reload()
  selectedId.value = created.id
  creatingId.value = created.id
  const file = byId.value.get(created.id)
  if (file) startRename(file)
}

// Upload state and pipeline live in ./uploadQueue (module scope) so a batch
// survives navigating to another app mid-upload. While mounted, insert each
// created file as it lands and true-up with one reload when the queue drains.
watch(lastCreated, created => {
  if (created && !allFiles.value.some(file => file.id === created.id)) {
    allFiles.value.push(created)
  }
})
watch(batchesDone, () => void reload())

function uploadFiles(files: File[]) {
  enqueueUploads(files, props.ctx.api, currentFolder.value)
}

function onFileInput(event: Event) {
  const input = event.target as HTMLInputElement
  if (input.files?.length) uploadFiles(Array.from(input.files))
  // Reset so picking the same file(s) again re-triggers the change event.
  input.value = ''
}

function onDrop(event: DragEvent) {
  dragover.value = false
  // An internal row drag that missed a folder target is a no-op, not an
  // upload; virtual mounts are read-only.
  if (draggingId.value || inVirtual.value) return
  if (event.dataTransfer?.files.length)
    uploadFiles(Array.from(event.dataTransfer.files))
}

// ----- rename (files & folders) -----
// Inline, in the row itself: double-click the name (or the Rename button in
// the detail panel). Enter/blur commits, Esc cancels.

const renamingId = ref<string | null>(null)
const renameValue = ref('')
// Function ref: a plain ref inside v-for collects an array, breaking
// .select()/.blur(); only one rename input ever renders at a time.
const renameInput = ref<HTMLInputElement | null>(null)

function setRenameInput(el: unknown) {
  renameInput.value = el as HTMLInputElement | null
}

let renameCancelled = false

// Entry created by newFolder and still being named; aborting deletes it.
const creatingId = ref<string | null>(null)

function startRename(file: Entry) {
  if (isVirtual(file)) return
  renamingId.value = file.id
  renameValue.value = fileName(file)
  nextTick(() => renameInput.value?.select())
}

function cancelRename() {
  renameCancelled = true
  renameInput.value?.blur()
}

// Commit on blur only: Enter just blurs, so the save can't double-fire.
async function onRenameBlur() {
  const cancelled = renameCancelled
  renameCancelled = false
  const id = renamingId.value
  renamingId.value = null
  const creating = creatingId.value === id
  creatingId.value = null
  const file = id ? byId.value.get(id) : undefined
  const name = renameValue.value.trim()
  if (!file) return
  if (creating && (cancelled || !name)) {
    await props.ctx.api.entries.delete(file.id)
    await reload()
    return
  }
  if (cancelled || !name || name === fileName(file)) return
  await props.ctx.api.entries.update(file.id, {
    title: name,
    data: { ...file.data, filename: name }
  })
  await reload()
}

// ----- drag & drop move -----

const draggingId = ref<string | null>(null)
const dropTargetId = ref<string | null>(null) // folder id, or "up" for the ".." row

const parentOfCurrent = computed(() => {
  const cur = currentFolder.value
    ? byId.value.get(currentFolder.value)
    : undefined
  return cur ? parentId(cur) : null
})

function goUp() {
  setFolder(parentOfCurrent.value, { push: true })
}

function onRowDragStart(file: Entry, event: DragEvent) {
  draggingId.value = file.id
  if (event.dataTransfer) {
    event.dataTransfer.setData('text/plain', file.id)
    event.dataTransfer.effectAllowed = 'move'
  }
}

function onRowDragEnd() {
  draggingId.value = null
  dropTargetId.value = null
}

// A folder can't be dropped into itself, one of its descendants, or a
// read-only virtual mount.
function canDropOn(target: Entry): boolean {
  const id = draggingId.value
  if (!id || id === target.id || !isFolder(target) || isVirtual(target)) {
    return false
  }
  return !chainTo(target.id).some(ancestor => ancestor.id === id)
}

function onRowDragOver(file: Entry, event: DragEvent) {
  if (!canDropOn(file)) return
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  dropTargetId.value = file.id
}

function onRowDragLeave(file: Entry) {
  if (dropTargetId.value === file.id) dropTargetId.value = null
}

function onRowDrop(file: Entry, event: DragEvent) {
  if (draggingId.value) {
    if (canDropOn(file)) void moveTo(file.id)
    // Only clear the highlight here; draggingId lives until dragend:
    // clearing it now lets a stray dragover between drop and dragend
    // re-light the upload glow (visible blink).
    dropTargetId.value = null
  } else {
    onDrop(event) // OS files dropped on a row upload into the current folder
  }
}

function onUpDragOver(event: DragEvent) {
  if (!draggingId.value) return
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  dropTargetId.value = 'up'
}

function onUpDrop() {
  if (draggingId.value) void moveTo(parentOfCurrent.value)
  dropTargetId.value = null
}

async function moveTo(parent: string | null) {
  const id = draggingId.value
  if (!id) return
  const file = byId.value.get(id)
  if (!file || parentId(file) === parent) return
  await props.ctx.api.entries.update(id, {
    data: { ...file.data, parent_id: parent }
  })
  await reload()
}

async function deleteItem(file: Entry) {
  const ok = await props.ctx.confirm.ask({ message: 'Delete this item?' })
  if (!ok) return
  await props.ctx.api.entries.delete(file.id)
  selectedId.value = null
  await reload()
}

onMounted(async () => {
  window.addEventListener('popstate', onPopState)
  await reload()
  const initial = new URLSearchParams(window.location.search).get('folder')
  if (initial) setFolder(initial)
})
onUnmounted(() => window.removeEventListener('popstate', onPopState))
</script>

<template>
  <p v-if="loading" class="fs-loading">Reading directory&hellip;</p>
  <p v-else-if="loadError" class="fs-loading">{{ loadError }}</p>
  <div v-else class="fs-layout">
    <div class="fs-main">
      <div class="fs-toolbar">
        <div class="fs-breadcrumbs">
          <template v-for="(part, index) in folderPath" :key="index">
            <span v-if="index > 0" class="fs-crumb-sep">/</span>
            <span class="fs-crumb" @click="navigateCrumb(index)">{{
              part.name
            }}</span>
          </template>
        </div>
        <div class="fs-actions">
          <input
            v-model="searchQuery"
            v-autofocus
            class="fs-search"
            type="text"
            placeholder="Search files..."
            aria-label="Search files"
          />
          <ComboBox
            v-model="typeFilter"
            class="fs-type-filter"
            :options="TYPE_FILTER_OPTIONS"
          />
          <button
            class="fs-btn fs-btn-icon"
            :title="
              showVirtual ? 'Hide virtual storage' : 'Show virtual storage'
            "
            @click="toggleVirtual"
          >
            <component :is="showVirtual ? Eye : EyeOff" :size="15" />
          </button>
          <button v-if="!inVirtual" class="fs-btn" @click="newFolder">
            + Folder
          </button>
          <label v-if="!inVirtual" class="fs-btn fs-upload-label">
            + Upload
            <input type="file" multiple hidden @change="onFileInput" />
          </label>
        </div>
      </div>
      <div v-if="uploading && uploadProgress" class="fs-uploading">
        <span class="fs-upload-count"
          >UPLOADING {{ uploadProgress.index }}/{{ uploadProgress.total }}</span
        >
        <span class="fs-upload-name">{{ uploadProgress.name }}</span>
        <span class="fs-upload-pct">{{
          uploadProgress.processing ? 'processing…' : uploadProgress.pct + '%'
        }}</span>
        <div class="fs-upload-bar">
          <div
            class="fs-upload-bar-fill"
            :style="{ width: uploadProgress.pct + '%' }"
          ></div>
        </div>
      </div>
      <div v-if="uploadErrors.length" class="fs-upload-errors" role="alert">
        <div v-for="(err, i) in uploadErrors" :key="i">{{ err }}</div>
        <button class="fs-upload-dismiss" @click="uploadErrors = []">
          Dismiss
        </button>
      </div>
      <div
        class="fs-list"
        :class="{ 'fs-dragover': dragover }"
        @dragover.prevent="dragover = !draggingId && !inVirtual"
        @dragleave="dragover = false"
        @drop.prevent="onDrop"
      >
        <div class="fs-list-head" aria-hidden="true">
          <span></span>
          <span>Name</span>
          <span class="fs-col-size">Size</span>
          <span>Added</span>
        </div>
        <div
          v-if="currentFolder && !searchQuery.trim()"
          class="fs-row fs-row--up"
          :class="{ 'fs-row--droptarget': dropTargetId === 'up' }"
          title="Parent directory"
          @dblclick="goUp"
          @dragover="onUpDragOver"
          @dragleave="dropTargetId === 'up' && (dropTargetId = null)"
          @drop.stop.prevent="onUpDrop"
        >
          <span class="fs-row-icon fs-row-icon--folder"
            ><Folder :size="16"
          /></span>
          <span class="fs-name-cell"><span class="fs-name">..</span></span>
          <span class="fs-size fs-col-size">-</span>
          <span></span>
        </div>
        <div
          v-for="file in displayed"
          :key="file.id"
          class="fs-row"
          :class="{
            'fs-row--active': file.id === selectedId,
            'fs-row--droptarget': dropTargetId === file.id,
            'fs-row--dragging': draggingId === file.id
          }"
          :draggable="renamingId !== file.id && !isVirtual(file)"
          @click="selectedId = file.id"
          @dblclick="openFolder(file)"
          @dragstart="onRowDragStart(file, $event)"
          @dragend="onRowDragEnd"
          @dragover="onRowDragOver(file, $event)"
          @dragleave="onRowDragLeave(file)"
          @drop.stop.prevent="onRowDrop(file, $event)"
        >
          <span
            class="fs-row-icon"
            :class="{ 'fs-row-icon--folder': isFolder(file) }"
          >
            <component :is="fileIcon(file)" :size="16" />
          </span>
          <span class="fs-name-cell">
            <input
              v-if="renamingId === file.id"
              :ref="setRenameInput"
              v-model="renameValue"
              class="fs-name fs-name-input"
              @click.stop
              @dblclick.stop
              @keydown.enter.prevent="renameInput?.blur()"
              @keydown.esc.prevent="cancelRename"
              @blur="onRenameBlur"
            />
            <span
              v-else
              class="fs-name"
              :title="isVirtual(file) ? undefined : 'Double-click to rename'"
              @dblclick.stop="
                isVirtual(file) ? openFolder(file) : startRename(file)
              "
              >{{ fileName(file)
              }}<span v-if="isFolder(file)" class="fs-slash">/</span></span
            >
            <button
              v-if="searchQuery.trim()"
              class="fs-row-path"
              title="Go to folder"
              @click.stop="goToFolderOf(file)"
            >
              {{ folderPathOf(file) }}
            </button>
          </span>
          <span class="fs-size fs-col-size">{{
            isFolder(file) ? '-' : formatFileSize(fileSize(file))
          }}</span>
          <span class="fs-date">{{
            file.inserted_at ? formatDate(file.inserted_at) : '-'
          }}</span>
        </div>
        <p v-if="displayed.length === 0" class="fs-empty">
          {{
            virtualLoading && inVirtual
              ? 'Reading directory…'
              : searchQuery || typeFilter
                ? 'No match.'
                : 'Empty directory'
          }}
        </p>
      </div>
    </div>
    <div class="fs-detail-col">
      <div v-if="selected" class="fs-detail">
        <img
          v-if="filePath(selected) && isImage(selected)"
          class="fs-detail-preview"
          :src="filePath(selected)!"
          :alt="fileName(selected)"
        />
        <span
          v-else
          class="fs-detail-icon"
          :class="{ 'fs-row-icon--folder': isFolder(selected) }"
        >
          <component :is="fileIcon(selected)" :size="40" :stroke-width="1.5" />
        </span>
        <h3 class="fs-detail-name">{{ fileName(selected) }}</h3>
        <div v-if="!isFolder(selected)" class="fs-detail-meta">
          <div class="fs-meta-row">
            <span class="fs-meta-label">Size</span>
            <span>{{ formatFileSize(fileSize(selected)) }}</span>
          </div>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Type</span>
            <span>{{ field(selected, 'mime_type') || 'Unknown' }}</span>
          </div>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Added</span>
            <span>{{
              selected.inserted_at ? formatDate(selected.inserted_at) : '-'
            }}</span>
          </div>
          <a
            v-if="filePath(selected)"
            class="fs-download"
            :href="filePath(selected)!"
            target="_blank"
            :download="fileName(selected)"
            >Download</a
          >
          <a
            v-if="field(selected, 'v') === 'note'"
            class="fs-download"
            href="#"
            @click.prevent="openVirtualFile(selected)"
            >Open in Notes</a
          >
          <a
            v-if="invoiceUrl(selected)"
            class="fs-download"
            :href="invoiceUrl(selected)!"
            target="_blank"
            rel="noopener"
            >Open invoice</a
          >
        </div>
        <div v-else class="fs-detail-meta">
          <div class="fs-meta-row">
            <span class="fs-meta-label">Type</span>
            <span>Folder</span>
          </div>
          <template v-if="selectedStats">
            <div class="fs-meta-row">
              <span class="fs-meta-label">Contents</span>
              <span>{{ contentsLabel }}</span>
            </div>
            <div class="fs-meta-row">
              <span class="fs-meta-label">Size</span>
              <span>{{ formatFileSize(selectedStats.size) }}</span>
            </div>
          </template>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Created</span>
            <span>{{
              selected.inserted_at ? formatDate(selected.inserted_at) : '-'
            }}</span>
          </div>
        </div>
        <template v-if="!isVirtual(selected)">
          <button class="fs-rename-btn" @click="startRename(selected)">
            Rename
          </button>
          <button class="fs-delete" @click="deleteItem(selected)">
            Delete
          </button>
        </template>
      </div>
      <p v-else class="fs-placeholder">Select a file to view details</p>
    </div>
  </div>
</template>

<style scoped>
.fs-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: var(--font-mono);
}
.fs-layout {
  display: flex;
  height: 100vh;
}
.fs-main {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.fs-detail-col {
  width: 300px;
  flex-shrink: 0;
  border-left: 1px solid var(--border);
  overflow-y: auto;
  padding: 1.5rem;
}
.fs-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--border);
  gap: 0.5rem;
}
/* The path is a prompt: ~/documents/taxes */
.fs-breadcrumbs {
  display: flex;
  align-items: center;
  gap: 0.15rem;
  font-family: var(--font-mono);
  font-size: 0.88rem;
  min-width: 0;
  overflow: hidden;
}
.fs-crumb {
  color: var(--text-muted);
  cursor: pointer;
  white-space: nowrap;
}
.fs-crumb:hover {
  color: var(--text);
}
.fs-crumb:first-child {
  color: var(--primary);
}
.fs-crumb:last-child {
  color: var(--text);
}
.fs-crumb-sep {
  color: var(--text-muted);
}
.fs-actions {
  display: flex;
  gap: 0.375rem;
  align-items: center;
  flex: 1;
  min-width: 0;
  justify-content: flex-end;
}
/* The search takes whatever the breadcrumbs leave, up to a sane cap. */
.fs-search {
  flex: 1;
  min-width: 160px;
  max-width: 480px;
  height: 32px;
  padding: 0 0.65rem;
  font-size: 0.85rem;
  border-radius: 8px;
}
.fs-type-filter {
  width: 150px;
  flex-shrink: 0;
}
/* Topbar controls share one control language: 32px outline capsules,
   primary on hover, same as the Contacts and Checklists topbars. */
.fs-type-filter :deep(.cb-control) {
  height: 32px;
  padding: 0 0.65rem;
  font-size: 0.85rem;
}
.fs-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  height: 32px;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0 0.75rem;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.85rem;
  white-space: nowrap;
  flex-shrink: 0;
}
.fs-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.fs-btn-icon {
  padding: 0 0.5rem;
}
/* Upload progress + errors, same language as Photos */
.fs-uploading {
  display: flex;
  flex-wrap: wrap; /* the bar takes its own full row: label changes can't resize it */
  align-items: center;
  gap: 0.35rem 0.75rem;
  padding: 0.5rem 1rem;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.08);
}
.fs-upload-count {
  letter-spacing: 0.08em;
  flex-shrink: 0;
}
.fs-upload-name {
  color: var(--text-muted);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.fs-upload-pct {
  flex-shrink: 0;
  margin-left: auto;
  text-align: right;
}
.fs-upload-bar {
  flex-basis: 100%;
  height: 6px;
  border-radius: 3px;
  background: rgba(var(--primary-rgb), 0.15);
  overflow: hidden;
}
.fs-upload-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 3px;
  transition: width 0.15s;
}
.fs-upload-errors {
  padding: 0.5rem 1rem;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  color: var(--danger);
  background: rgba(255, 92, 122, 0.08);
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}
.fs-upload-dismiss {
  align-self: flex-start;
  margin-top: 0.25rem;
  padding: 0.2rem 0.6rem;
  font-size: 0.78rem;
  background: transparent;
  border: 1px solid var(--danger);
  color: var(--danger);
  border-radius: 6px;
  cursor: pointer;
}
.fs-upload-dismiss:hover {
  background: var(--danger);
  color: var(--primary-contrast);
}

/* Directory listing, ls style */
.fs-list {
  flex: 1;
  overflow-y: auto;
  padding: 0.5rem 0.75rem 0.75rem;
}
.fs-list-head,
.fs-row {
  display: grid;
  grid-template-columns: 24px minmax(0, 1fr) 120px 110px;
  gap: 1rem;
  align-items: center;
  padding: 0.35rem 0.5rem;
}
.fs-list-head {
  position: sticky;
  top: -0.5rem; /* cancel .fs-list padding */
  z-index: 2;
  background: var(--bg);
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
  border-bottom: 1px solid var(--border);
  margin-bottom: 1em;
}
.fs-row {
  border-radius: var(--radius);
  cursor: pointer;
  transition: background 0.1s;
}
.fs-row:hover {
  background: var(--bg-hover);
}
/* Cursor row: violet rail + tint, same language as Contacts */
.fs-row--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 var(--radius) var(--radius) 0;
}
.fs-row--droptarget {
  background: rgba(var(--primary-rgb), 0.15);
  box-shadow: inset 0 0 0 1px var(--primary);
}
.fs-row--dragging {
  opacity: 0.4;
}
.fs-row--up .fs-name {
  color: var(--text-muted);
}
.fs-row-icon {
  display: flex;
  align-items: center;
  color: var(--text-muted);
}
.fs-row-icon--folder {
  color: var(--primary);
}
.fs-name-cell {
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}
.fs-name {
  font-family: var(--font-mono);
  font-size: 0.88rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 100%;
}
.fs-row-path {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 100%;
}
.fs-row-path:hover {
  color: var(--primary);
  background: none;
  text-decoration: underline;
}
.fs-slash {
  color: var(--text-muted);
}
.fs-size,
.fs-date {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.fs-col-size {
  text-align: right;
}
.fs-list.fs-dragover {
  outline: 2px dashed var(--primary);
  outline-offset: -4px;
  background: rgba(var(--primary-rgb), 0.05);
}
.fs-empty {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem;
  font-family: var(--font-mono);
  font-size: 0.88rem;
}
.fs-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem 1rem;
  font-family: var(--font-mono);
  font-size: 0.88rem;
}
.fs-detail {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
}
.fs-detail-icon {
  color: var(--text-muted);
}
.fs-detail-preview {
  max-width: 100%;
  max-height: 220px;
  object-fit: contain;
  border-radius: 6px;
  border: 1px solid var(--border);
}
.fs-detail-name {
  margin: 0;
  font-family: var(--font-mono);
  font-size: 0.95rem;
  text-align: center;
  word-break: break-word;
}
.fs-detail-meta {
  width: 100%;
  margin-top: 0.75rem;
}
.fs-meta-row {
  display: flex;
  justify-content: space-between;
  padding: 0.4rem 0;
  font-size: 0.85rem;
  border-bottom: 1px solid var(--border);
}
.fs-meta-label {
  color: var(--text-muted);
}
.fs-download {
  display: block;
  text-align: center;
  margin-top: 0.75rem;
  color: var(--primary);
  text-decoration: none;
  font-size: 0.9rem;
}
.fs-download:hover {
  text-decoration: underline;
}
.fs-name-input {
  width: 100%;
  padding: 0.3rem 0.5rem;
  border-radius: 4px;
}
.fs-rename-btn {
  margin-top: 1rem;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.4rem 1rem;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.85rem;
  width: 100%;
}
.fs-rename-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.fs-delete {
  margin-top: 0.5rem;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.4rem 1rem;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.85rem;
  width: 100%;
}
.fs-delete:hover {
  border-color: var(--danger);
  color: var(--danger);
}
</style>
