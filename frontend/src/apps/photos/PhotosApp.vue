<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted, onUnmounted } from 'vue'
import ComboBox from '../../components/ComboBox.vue'
import DateInput from '../../components/DateInput.vue'
import type { AppContext, Entry } from '../types'
import { formatFileSize } from '../../types'
import {
  formatDate,
  formatDateTime,
  utcToZonedParts,
  zonedToUtcISO
} from '../../lib/datetime'
import { contactName, contactInitials } from '../../lib/contact'
import FaceChip from './FaceChip.vue'
import {
  clusterFaces,
  facesOf,
  namedReferences,
  type FaceCluster
} from './faces'
import {
  batchesDone,
  captureVideoFrame,
  enqueueUploads,
  lastCreated,
  uploadErrors,
  uploadProgress,
  uploading
} from './uploadQueue'

const props = defineProps<{ ctx: AppContext }>()

interface Person {
  id: string
  name: string
}

const allPhotos = ref<Entry[]>([])
const allContacts = ref<Entry[]>([])
const albumFilter = ref('')
const tagFilter = ref('')
const peopleFilter = ref('')
const loading = ref(true)
const loadError = ref('')
// Long backfill/scan loops check this so they stop when the app is unmounted
// (navigating away) instead of running on in the background.
let alive = true
const selectionMode = ref(false)
const peopleSearchActive = ref(false)
const peopleSearchQuery = ref('')
const tagModalActive = ref(false)
const tagModalQuery = ref('')
const selectedIds = ref<Set<string>>(new Set())
const broken = ref<Set<string>>(new Set())

const peopleInput = ref<HTMLInputElement | null>(null)
const tagInput = ref<HTMLInputElement | null>(null)

function field(e: Entry, k: string): unknown {
  return e.data[k]
}
const getThumbPath = (e: Entry) =>
  (field(e, 'thumb_path') || field(e, 'path')) as string
const isVideo = (e: Entry) =>
  ((field(e, 'mime_type') as string) || '').startsWith('video/')

// Videos never mount a <video> in the grid: one media decoder per cell
// wedges the browser on large libraries. They show the JPEG frame captured
// at upload time (thumb_path), or a plain play tile when there is none.
const hasGridImage = (e: Entry) => !isVideo(e) || !!field(e, 'thumb_path')
const getTags = (e: Entry): string[] => (e.data.tags as string[]) || []
const getPeople = (e: Entry): Person[] => (e.data.people as Person[]) || []

const albums = computed(() => {
  const set = new Set<string>()
  for (const p of allPhotos.value) {
    const a = field(p, 'album') as string
    if (a) set.add(a)
  }
  return Array.from(set).sort()
})

const allTags = computed(() => {
  const set = new Set<string>()
  for (const p of allPhotos.value) for (const t of getTags(p)) set.add(t)
  return Array.from(set).sort()
})

const allPeople = computed<Person[]>(() => {
  const map = new Map<string, string>()
  for (const p of allPhotos.value)
    for (const person of getPeople(p)) map.set(person.id, person.name)
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name))
})

const filtered = computed(() => {
  let list = allPhotos.value
  if (albumFilter.value)
    list = list.filter(p => field(p, 'album') === albumFilter.value)
  if (tagFilter.value)
    list = list.filter(p => getTags(p).includes(tagFilter.value))
  if (peopleFilter.value)
    list = list.filter(p =>
      getPeople(p).some(pp => pp.id === peopleFilter.value)
    )
  return list
})

// ----- grouping by shot date (occurred_at, i.e. EXIF date, else upload date) -----

type GroupBy = '' | 'year' | 'month' | 'week'
const GROUP_BY_KEY = 'servant_photos_group_by'

function storedGroupBy(): GroupBy {
  const v = localStorage.getItem(GROUP_BY_KEY)
  return v === 'year' || v === 'month' || v === 'week' ? v : ''
}

const groupBy = ref<GroupBy>(storedGroupBy())

const albumOptions = computed(() => [
  { value: '', label: 'All photos' },
  ...albums.value
])

const GROUP_OPTIONS = [
  { value: '', label: 'No grouping' },
  { value: 'year', label: 'By year' },
  { value: 'month', label: 'By month' },
  { value: 'week', label: 'By week' }
]

function onGroupByChange(v: string) {
  groupBy.value = v as GroupBy
  localStorage.setItem(GROUP_BY_KEY, v)
}

const photoDate = (p: Entry) => (p.occurred_at || p.inserted_at) as string

// Thumb chips are tiny: first name only (the full name stays in the title
// tooltip, the filter bar and the viewer meta).
const firstName = (name: string) => name.trim().split(/\s+/)[0]

function isoWeek(
  y: number,
  m: number,
  d: number
): { year: number; week: number } {
  const date = new Date(Date.UTC(y, m - 1, d))
  const dayNum = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - dayNum)
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  const week = Math.ceil(
    ((date.getTime() - yearStart.getTime()) / 86_400_000 + 1) / 7
  )
  return { year: date.getUTCFullYear(), week }
}

interface PhotoGroup {
  key: string
  label: string
  photos: Entry[]
}

const groups = computed<PhotoGroup[]>(() => {
  if (!groupBy.value) return [{ key: '', label: '', photos: filtered.value }]

  const list = [...filtered.value].sort((a, b) =>
    photoDate(a) < photoDate(b) ? 1 : -1
  )
  const out: PhotoGroup[] = []
  const idx = new Map<string, number>()

  for (const p of list) {
    const iso = photoDate(p)
    const dateStr = utcToZonedParts(iso).date // wall-clock day in the user's tz
    let key: string
    let label: string

    if (groupBy.value === 'year') {
      key = dateStr.slice(0, 4)
      label = key
    } else if (groupBy.value === 'month') {
      key = dateStr.slice(0, 7)
      label = formatDate(iso, { month: 'long', year: 'numeric' })
    } else {
      const [y, m, d] = dateStr.split('-').map(Number)
      const w = isoWeek(y, m, d)
      key = `${w.year}-W${String(w.week).padStart(2, '0')}`
      label = `W${String(w.week).padStart(2, '0')} · ${w.year}`
    }

    let i = idx.get(key)
    if (i === undefined) {
      i = out.length
      idx.set(key, i)
      out.push({ key, label, photos: [] })
    }
    out[i].photos.push(p)
  }
  return out
})

const selCount = computed(() => selectedIds.value.size)

// ----- preview backfill (thumbnails/display JPEGs missing on old entries) -----

const rebuilding = ref(false)
const missingPreviews = computed(
  () =>
    allPhotos.value.filter(
      p => !isVideo(p) && (!p.data.thumb_path || !p.data.display_path)
    ).length
)

async function rebuildPreviews() {
  rebuilding.value = true
  try {
    await props.ctx.api.fetch('/api/entries/backfill_media', { method: 'POST' })
    // The server regenerates in the background: poll until nothing is
    // missing anymore, up to ~1 minute.
    for (let i = 0; i < 15; i++) {
      await new Promise(r => setTimeout(r, 4000))
      if (!alive) break
      await reload()
      if (missingPreviews.value === 0) break
    }
  } finally {
    rebuilding.value = false
  }
}
// ----- video thumbnails backfill (client-side: the server has no video decoder) -----

const missingVideoThumbs = computed(
  () =>
    allPhotos.value.filter(p => isVideo(p) && !field(p, 'thumb_path')).length
)
const fixingVideos = ref<{ done: number; total: number } | null>(null)

// Downloads each video, captures a frame in the browser and stores it as the
// entry's thumb_path (same pipeline as fresh uploads).
async function rebuildVideoThumbs() {
  const targets = allPhotos.value.filter(
    p => isVideo(p) && !field(p, 'thumb_path')
  )
  if (!targets.length || fixingVideos.value) return
  fixingVideos.value = { done: 0, total: targets.length }
  for (const p of targets) {
    if (!alive) break
    try {
      const path = field(p, 'path') as string
      if (!path) throw new Error('no file path')
      const res = await fetch(path)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const blob = await res.blob()
      const name = (field(p, 'filename') as string) || 'video'
      const frame = await captureVideoFrame(
        new File([blob], name, {
          type: (field(p, 'mime_type') as string) || blob.type
        })
      )
      if (!frame) throw new Error("browser can't decode this video")
      const t = (await props.ctx.api.upload(
        frame,
        'photos'
      )) as unknown as Record<string, unknown>
      await props.ctx.api.entries.update(p.id, {
        data: { ...p.data, thumb_path: t.path }
      })
    } catch (e) {
      uploadErrors.value.push(
        `${field(p, 'filename') || 'video'}: ${e instanceof Error ? e.message : 'thumbnail failed'}`
      )
    } finally {
      if (fixingVideos.value) fixingVideos.value.done++
    }
  }
  fixingVideos.value = null
  await reload()
}

// ----- face detection (browser-side, see faceScan.ts) -----

// The photo the detector can decode: the 1920px display JPEG when it
// exists, else the original for browser-readable formats. HEIC originals
// without a display JPEG need "Fix previews" first.
function faceScanSrc(p: Entry): string | null {
  if (isVideo(p)) return null
  const display = field(p, 'display_path') as string
  if (display) return display
  const mime = ((field(p, 'mime_type') as string) || '').toLowerCase()
  const path = field(p, 'path') as string
  if (path && mime.startsWith('image/') && !mime.includes('hei')) return path
  return null
}

const missingFaces = computed(
  () =>
    allPhotos.value.filter(p => !('faces' in p.data) && faceScanSrc(p)).length
)
const anyFaces = computed(() => allPhotos.value.some(p => facesOf(p).length))
const scanningFaces = ref<{ done: number; total: number } | null>(null)

async function scanFaces() {
  const targets = allPhotos.value.filter(
    p => !('faces' in p.data) && faceScanSrc(p)
  )
  if (!targets.length || scanningFaces.value) return
  scanningFaces.value = { done: 0, total: targets.length }
  const { detectFaces } = await import('./faceScan')
  for (const p of targets) {
    if (!alive) break
    try {
      const faces = await detectFaces(faceScanSrc(p)!)
      const updated = await props.ctx.api.entries.update(p.id, {
        data: { ...p.data, faces }
      })
      allPhotos.value = allPhotos.value.map(x =>
        x.id === updated.id ? updated : x
      )
    } catch (e) {
      uploadErrors.value.push(
        `${field(p, 'filename') || 'photo'}: ${
          e instanceof Error ? e.message : 'face scan failed'
        }`
      )
    } finally {
      if (scanningFaces.value) scanningFaces.value.done++
    }
  }
  scanningFaces.value = null
}

// ----- naming face clusters -----

interface ClusterRow {
  cluster: FaceCluster
  assign: string // selected contact id
  done?: string // contact name once tagged
}

const faceModalActive = ref(false)
const faceRows = ref<ClusterRow[]>([])
const namingCluster = ref(false)

const contactOptions = computed(() => [
  { value: '', label: 'Who is this?' },
  ...allContacts.value
    .map(c => ({ value: c.id, label: contactName(c) }))
    .sort((a, b) => a.label.localeCompare(b.label))
])

const photoById = computed(() => new Map(allPhotos.value.map(p => [p.id, p])))
function chipSrc(photoId: string): string {
  const p = photoById.value.get(photoId)
  return p ? getThumbPath(p) : ''
}

function openFaceModal() {
  faceRows.value = clusterFaces(
    allPhotos.value,
    namedReferences(allPhotos.value)
  ).map(c => ({ cluster: c, assign: c.suggestedPersonId || '' }))
  faceModalActive.value = true
}

// Tags every photo of the cluster with the chosen contact (through the
// regular people mechanism) and pins the person on each face, making it a
// reference for future suggestions.
async function nameCluster(row: ClusterRow) {
  const contact = allContacts.value.find(c => c.id === row.assign)
  if (!contact || row.done || namingCluster.value) return
  namingCluster.value = true
  const name = contactName(contact)
  try {
    const byPhoto = new Map<string, number[]>()
    for (const r of row.cluster.faces) {
      byPhoto.set(r.photoId, [...(byPhoto.get(r.photoId) || []), r.index])
    }
    for (const [photoId, indexes] of byPhoto) {
      const photo = photoById.value.get(photoId)
      if (!photo) continue
      const faces = facesOf(photo).map((f, idx) =>
        indexes.includes(idx) ? { ...f, person_id: contact.id } : f
      )
      const people = getPeople(photo)
      const newPeople = people.some(pp => pp.id === contact.id)
        ? people
        : [...people, { id: contact.id, name }]
      const updated = await props.ctx.api.entries.update(photoId, {
        data: { ...photo.data, faces, people: newPeople }
      })
      allPhotos.value = allPhotos.value.map(x =>
        x.id === updated.id ? updated : x
      )
    }
    row.done = name
  } catch (e) {
    uploadErrors.value.push(
      `tagging failed: ${e instanceof Error ? e.message : 'unknown error'}`
    )
  } finally {
    namingCluster.value = false
  }
}

const hasFilters = computed(
  () => allTags.value.length > 0 || allPeople.value.length > 0
)

const matchingContacts = computed(() => {
  if (!peopleSearchActive.value) return []
  const q = peopleSearchQuery.value.toLowerCase()
  if (!q) {
    // Before any typing, offer the people already tagged on other photos:
    // recurring people are one click away instead of requiring a search.
    return allPeople.value
      .map(p => allContacts.value.find(c => c.id === p.id))
      .filter((c): c is Entry => !!c)
      .slice(0, 8)
  }
  return allContacts.value
    .filter(c =>
      ((c.data.display_name as string) || c.title || '')
        .toLowerCase()
        .includes(q)
    )
    .slice(0, 8)
})

const currentTags = computed(() => {
  const counts = new Set<string>()
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find(p => p.id === id)
    if (photo) for (const t of getTags(photo)) counts.add(t)
  }
  return Array.from(counts).sort()
})

const tagSuggestions = computed(() => {
  if (!tagModalQuery.value) return allTags.value
  const q = tagModalQuery.value.toLowerCase()
  return allTags.value.filter(
    t => t.toLowerCase().includes(q) && t.toLowerCase() !== q
  )
})

function setFilter(opts: { tag?: string; person?: string }) {
  if (opts.tag !== undefined) {
    tagFilter.value = opts.tag
    peopleFilter.value = ''
  }
  if (opts.person !== undefined) {
    peopleFilter.value = opts.person
    tagFilter.value = ''
  }
  if (opts.tag === '' && opts.person === '') {
    tagFilter.value = ''
    peopleFilter.value = ''
  }
}

async function reload() {
  loadError.value = ''
  try {
    const [photos, contacts] = await Promise.all([
      props.ctx.api.entries.list({ kind: 'photo' }),
      allContacts.value.length
        ? Promise.resolve(allContacts.value)
        : props.ctx.api.entries.list({ kind: 'contact' })
    ])
    allPhotos.value = photos.sort(
      (a, b) =>
        new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime()
    )
    allContacts.value = contacts
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'Failed to load photos'
  } finally {
    loading.value = false
  }
}

// Upload state and pipeline live in ./uploadQueue (module scope) so a batch
// survives navigating to another app mid-upload. While mounted, created
// photos land in the grid in 1s batches (one regroup/re-render per flush,
// not per upload: a 500-file batch would churn the grid 500 times) and a
// single reload trues everything up when the queue drains.
let pendingCreated: Entry[] = []
let createdFlushTimer: ReturnType<typeof setTimeout> | undefined

function flushCreated() {
  createdFlushTimer = undefined
  const fresh = pendingCreated.filter(
    c => !allPhotos.value.some(p => p.id === c.id)
  )
  pendingCreated = []
  if (fresh.length) allPhotos.value.unshift(...fresh)
}

watch(lastCreated, created => {
  if (!created) return
  pendingCreated.push(created)
  createdFlushTimer ??= setTimeout(flushCreated, 1000)
})
watch(batchesDone, () => void reload())

function uploadFiles(files: File[]) {
  enqueueUploads(files, props.ctx.api, albumFilter.value || null)
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement
  if (input.files?.length) uploadFiles(Array.from(input.files))
  // Reset so picking the same file(s) again re-triggers the change event.
  input.value = ''
}
const dragover = ref(false)
function onDrop(e: DragEvent) {
  dragover.value = false
  if (e.dataTransfer?.files.length)
    uploadFiles(Array.from(e.dataTransfer.files))
}

// Anchor for shift-click range selection (last photo clicked in select mode).
let lastClickedId: string | null = null

function onThumbClick(p: Entry, e?: MouseEvent) {
  if (selectionMode.value) {
    // Shift extends from the anchor to the clicked photo, in grid order.
    if (e?.shiftKey && lastClickedId && lastClickedId !== p.id) {
      const list = filtered.value
      const from = list.findIndex(x => x.id === lastClickedId)
      const to = list.findIndex(x => x.id === p.id)
      if (from !== -1 && to !== -1) {
        const [lo, hi] = from < to ? [from, to] : [to, from]
        for (let i = lo; i <= hi; i++) selectedIds.value.add(list[i].id)
        lastClickedId = p.id
        return
      }
    }
    if (selectedIds.value.has(p.id)) selectedIds.value.delete(p.id)
    else selectedIds.value.add(p.id)
    lastClickedId = p.id
  } else if (e?.shiftKey) {
    // Shift-click from browse mode jumps straight into selection.
    selectionMode.value = true
    selectedIds.value.add(p.id)
    lastClickedId = p.id
  } else {
    openViewer(p.id)
  }
}

function enterSelect() {
  selectionMode.value = true
  selectedIds.value.clear()
  lastClickedId = null
}
function cancelSelect() {
  selectionMode.value = false
  selectedIds.value.clear()
  peopleSearchActive.value = false
  lastClickedId = null
}
function selectAll() {
  for (const p of filtered.value) selectedIds.value.add(p.id)
}
function deselect() {
  selectedIds.value.clear()
}

async function deletePhotos(ids: string[]) {
  if (!ids.length) return
  const single =
    ids.length === 1 ? allPhotos.value.find(p => p.id === ids[0]) : undefined
  const label = single
    ? `"${single.title || (single.data.filename as string) || 'this photo'}"`
    : `${ids.length} photos`
  const ok = await props.ctx.confirm.ask({
    message: `Delete ${label}?`,
    danger: true,
    confirmLabel: 'Delete'
  })
  if (!ok) return
  loadError.value = ''
  try {
    for (const id of ids) await props.ctx.api.entries.delete(id)
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'Delete failed'
  }
  selectedIds.value.clear()
  selectionMode.value = false
  await reload()
}

// Rotation keeps the selection: fixing an orientation often takes a second
// quarter turn, so the user should not have to reselect.
const rotating = ref(false)
async function rotateSelected(angle: 90 | 270) {
  const targets = [...selectedIds.value]
    .map(id => allPhotos.value.find(p => p.id === id))
    .filter((p): p is Entry => !!p && !isVideo(p))
  if (!targets.length || rotating.value) return
  rotating.value = true
  try {
    for (const p of targets) {
      try {
        await props.ctx.api.fetch(
          `/api/entries/${p.id}/rotate_photo?angle=${angle}`,
          { method: 'POST' }
        )
      } catch (e) {
        uploadErrors.value.push(
          `${(p.data.filename as string) || p.title || p.id}: ${
            e instanceof Error ? e.message : 'rotation failed'
          }`
        )
      }
    }
    await reload()
  } finally {
    rotating.value = false
  }
}

// ponytail: sets occurred_at + data.date_taken only; the EXIF bytes inside
// the file are not rewritten (needs exiftool or a lossy vips re-encode).
const dateModalActive = ref(false)
const dateModalDate = ref('')
const dateModalTime = ref('')

function openDateModal() {
  const first = allPhotos.value.find(p => selectedIds.value.has(p.id))
  const iso = first
    ? (first.data.date_taken as string) || photoDate(first)
    : new Date().toISOString()
  const parts = utcToZonedParts(iso)
  dateModalDate.value = parts.date
  dateModalTime.value = parts.time
  dateModalActive.value = true
}
function closeDateModal() {
  dateModalActive.value = false
}
async function applyDate() {
  if (!dateModalDate.value) return
  const iso = zonedToUtcISO(dateModalDate.value, dateModalTime.value || '00:00')
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(p => p.id === id)
      if (!photo) continue
      await props.ctx.api.entries.update(id, {
        occurred_at: iso,
        data: { ...photo.data, date_taken: iso }
      })
    }
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'Failed to set the date'
  } finally {
    dateModalActive.value = false
    selectedIds.value.clear()
    selectionMode.value = false
    await reload()
  }
}

function openTagPeople() {
  peopleSearchActive.value = true
  peopleSearchQuery.value = ''
  nextTick(() => peopleInput.value?.focus())
}
function onPeopleKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    peopleSearchActive.value = false
    peopleSearchQuery.value = ''
  }
}
async function tagWithContact(c: Entry) {
  const name = contactName(c)
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(p => p.id === id)
      if (!photo) continue
      const existing = getPeople(photo)
      if (existing.some(pp => pp.id === c.id)) continue
      await props.ctx.api.entries.update(id, {
        data: { ...photo.data, people: [...existing, { id: c.id, name }] }
      })
    }
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'Failed to tag people'
  } finally {
    peopleSearchActive.value = false
    peopleSearchQuery.value = ''
    selectedIds.value.clear()
    selectionMode.value = false
    await reload()
  }
}

function openTagModal() {
  tagModalActive.value = true
  tagModalQuery.value = ''
  nextTick(() => tagInput.value?.focus())
}
function closeTagModal() {
  tagModalActive.value = false
  tagModalQuery.value = ''
}
async function applyTag(tag: string) {
  const t = tag.trim()
  if (!t) return
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(p => p.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      if (existing.includes(t)) continue
      await props.ctx.api.entries.update(id, {
        data: { ...photo.data, tags: [...existing, t] }
      })
    }
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : 'Failed to add the tag'
  } finally {
    tagModalActive.value = false
    tagModalQuery.value = ''
    selectedIds.value.clear()
    selectionMode.value = false
    await reload()
  }
}
async function removeTagFromSelected(tag: string) {
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(p => p.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      if (!existing.includes(tag)) continue
      await props.ctx.api.entries.update(id, {
        data: { ...photo.data, tags: existing.filter(t => t !== tag) }
      })
    }
  } catch (e) {
    loadError.value =
      e instanceof Error ? e.message : 'Failed to remove the tag'
  } finally {
    const photos = await props.ctx.api.entries.list({ kind: 'photo' })
    allPhotos.value = photos.sort(
      (a, b) =>
        new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime()
    )
    nextTick(() => tagInput.value?.focus())
  }
}
async function removeTagAction() {
  if (!tagFilter.value) return
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(p => p.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      await props.ctx.api.entries.update(id, {
        data: {
          ...photo.data,
          tags: existing.filter(t => t !== tagFilter.value)
        }
      })
    }
  } catch (e) {
    loadError.value =
      e instanceof Error ? e.message : 'Failed to remove the tag'
  } finally {
    selectedIds.value.clear()
    selectionMode.value = false
    await reload()
  }
}

function openViewer(photoId: string, opts: { push?: boolean } = {}) {
  // Opening a photo is a history entry so the browser back button closes it.
  if (opts.push !== false) {
    history.pushState(null, '', `/apps/photos?photo=${photoId}`)
  }
  const photos = filtered.value
  const items = photos.map(p => {
    const meta: Record<string, string | number | null> = {}
    if (p.data.date_taken)
      meta['Date taken'] = formatDateTime(p.data.date_taken as string)
    if (p.data.camera) meta['Camera'] = p.data.camera as string
    if (p.data.latitude != null)
      meta['Location'] =
        `${(p.data.latitude as number).toFixed(5)}, ${(p.data.longitude as number).toFixed(5)}`
    if (p.data.size) meta['Size'] = formatFileSize(p.data.size as number)
    if (p.data.filename) meta['Filename'] = p.data.filename as string
    if (p.data.album) meta['Album'] = p.data.album as string
    const tags = getTags(p)
    if (tags.length) meta['Tags'] = tags.join(', ')
    const photoPeople = getPeople(p)
    if (photoPeople.length)
      meta['People'] = photoPeople.map(pp => pp.name).join(', ')
    return {
      id: p.id,
      // display_path is the fast 1920px JPEG; the original stays one click away
      src: (field(p, 'display_path') || field(p, 'path')) as string,
      fullSrc: field(p, 'display_path')
        ? (field(p, 'path') as string)
        : undefined,
      video: isVideo(p),
      title: p.title || undefined,
      subtitle: (field(p, 'album') as string) || undefined,
      meta: Object.keys(meta).length ? meta : undefined
    }
  })
  const idx = photos.findIndex(p => p.id === photoId)
  // The deep-linked photo may be outside the active filter; don't silently open
  // the first one (idx -1 -> 0) as if it were the requested photo.
  if (idx === -1) return
  props.ctx.viewer.open(items, idx)
}

watch(peopleSearchActive, active => {
  if (active) nextTick(() => peopleInput.value?.focus())
})

function onPopState() {
  const id = new URLSearchParams(window.location.search).get('photo')
  if (id) openViewer(id, { push: false })
  else props.ctx.viewer.close()
}

onMounted(async () => {
  window.addEventListener('popstate', onPopState)
  props.ctx.viewer.onDelete(async id => {
    await props.ctx.api.entries.delete(id)
    await reload()
  })
  // Backdrop/Esc/Close must also drop the ?photo= deep link.
  props.ctx.viewer.onClose(() => {
    if (new URLSearchParams(window.location.search).get('photo')) {
      history.replaceState(null, '', '/apps/photos')
    }
  })
  await reload()
  const initial = new URLSearchParams(window.location.search).get('photo')
  if (initial) openViewer(initial, { push: false })
})
onUnmounted(() => {
  alive = false
  clearTimeout(createdFlushTimer)
  window.removeEventListener('popstate', onPopState)
})
</script>

<template>
  <p v-if="loading" class="ph-loading">Scanning archive&hellip;</p>
  <p v-else-if="loadError" class="ph-loading">{{ loadError }}</p>
  <div
    v-else
    class="ph-layout"
    :class="{ 'ph-dragover': dragover }"
    @dragover.prevent="dragover = true"
    @dragleave="dragover = false"
    @drop.prevent="onDrop"
  >
    <!-- Selection toolbar -->
    <div v-if="selectionMode" class="ph-toolbar">
      <span class="ph-sel-count">{{ selCount }} SELECTED</span>
      <div class="ph-actions">
        <button class="ph-btn" @click="selectAll">Select all</button>
        <button class="ph-btn" @click="deselect">Deselect</button>
        <button
          class="ph-btn ph-btn--primary"
          :disabled="selCount === 0"
          @click="openTagModal"
        >
          Tag
        </button>
        <button
          class="ph-btn"
          :disabled="selCount === 0"
          @click="openTagPeople"
        >
          Tag people
        </button>
        <button
          class="ph-btn"
          :disabled="selCount === 0 || rotating"
          title="Rotate left"
          aria-label="Rotate left"
          @click="rotateSelected(270)"
        >
          &#10226;
        </button>
        <button
          class="ph-btn"
          :disabled="selCount === 0 || rotating"
          title="Rotate right"
          aria-label="Rotate right"
          @click="rotateSelected(90)"
        >
          &#10227;
        </button>
        <button
          class="ph-btn"
          :disabled="selCount === 0"
          @click="openDateModal"
        >
          Set date
        </button>
        <button
          class="ph-btn ph-btn--danger"
          :disabled="selCount === 0"
          @click="deletePhotos([...selectedIds])"
        >
          Delete
        </button>
        <button
          v-if="tagFilter"
          class="ph-btn ph-btn--danger"
          :disabled="selCount === 0"
          @click="removeTagAction"
        >
          Remove "{{ tagFilter }}"
        </button>
        <button class="ph-btn" @click="cancelSelect">Cancel</button>
      </div>
    </div>
    <div v-if="selectionMode && peopleSearchActive" class="ph-people-search">
      <input
        ref="peopleInput"
        class="ph-people-input"
        type="text"
        placeholder="Search contacts..."
        v-model="peopleSearchQuery"
        @keydown="onPeopleKeydown"
      />
      <div v-if="matchingContacts.length" class="ph-people-results">
        <div
          v-for="c in matchingContacts"
          :key="c.id"
          class="ph-people-result"
          @click="tagWithContact(c)"
        >
          <img
            v-if="c.data.photo"
            class="ph-people-avatar"
            :src="c.data.photo as string"
            alt=""
          />
          <span v-else class="ph-people-avatar ph-people-avatar--init">{{
            contactInitials(contactName(c))
          }}</span>
          <span>{{ contactName(c) }}</span>
        </div>
      </div>
      <div v-else-if="peopleSearchQuery" class="ph-people-no-results">
        No contacts found
      </div>
    </div>

    <!-- Normal toolbar -->
    <div v-if="!selectionMode" class="ph-toolbar">
      <div class="ph-filters">
        <ComboBox
          v-if="albumOptions.length > 1"
          class="ph-album-filter"
          v-model="albumFilter"
          :options="albumOptions"
        />
        <ComboBox
          class="ph-album-filter ph-group-select"
          :model-value="groupBy"
          :options="GROUP_OPTIONS"
          @update:model-value="onGroupByChange"
        />
        <span class="ph-status"
          >{{ filtered.length }} <span class="ph-status-unit">IMG</span></span
        >
      </div>
      <div class="ph-actions">
        <button
          v-if="missingPreviews > 0"
          class="ph-btn"
          :disabled="rebuilding"
          @click="rebuildPreviews"
        >
          {{ rebuilding ? 'Rebuilding…' : `Fix previews (${missingPreviews})` }}
        </button>
        <button
          v-if="missingVideoThumbs > 0 || fixingVideos"
          class="ph-btn"
          :disabled="!!fixingVideos"
          @click="rebuildVideoThumbs"
        >
          {{
            fixingVideos
              ? `Fixing videos ${fixingVideos.done}/${fixingVideos.total}…`
              : `Fix video thumbs (${missingVideoThumbs})`
          }}
        </button>
        <button
          v-if="missingFaces > 0 || scanningFaces"
          class="ph-btn"
          :disabled="!!scanningFaces"
          @click="scanFaces"
        >
          {{
            scanningFaces
              ? `Scanning faces ${scanningFaces.done}/${scanningFaces.total}…`
              : `Scan faces (${missingFaces})`
          }}
        </button>
        <button v-if="anyFaces" class="ph-btn" @click="openFaceModal">
          Faces
        </button>
        <button class="ph-btn" @click="enterSelect">Select</button>
        <label class="ph-btn">
          + Upload<input
            type="file"
            accept="image/*,video/*,.heic,.heif"
            multiple
            hidden
            @change="onFileInput"
          />
        </label>
      </div>
    </div>

    <!-- Tag / people filter bar -->
    <div v-if="hasFilters" class="ph-tags-bar">
      <span
        class="ph-tag-pill"
        :class="{ 'ph-tag-pill--active': !tagFilter && !peopleFilter }"
        @click="setFilter({ tag: '', person: '' })"
        >All</span
      >
      <span
        v-for="t in allTags"
        :key="'t' + t"
        class="ph-tag-pill"
        :class="{ 'ph-tag-pill--active': t === tagFilter }"
        @click="setFilter({ tag: t })"
        >{{ t }}</span
      >
      <span v-if="allPeople.length" class="ph-tag-sep"></span>
      <span
        v-for="p in allPeople"
        :key="'p' + p.id"
        class="ph-tag-pill ph-tag-pill--person"
        :class="{ 'ph-tag-pill--active': p.id === peopleFilter }"
        :title="p.name"
        @click="setFilter({ person: p.id })"
        >{{ firstName(p.name) }}</span
      >
    </div>

    <div v-if="uploading && uploadProgress" class="ph-uploading">
      <span class="ph-upload-count"
        >UPLOADING {{ uploadProgress.index }}/{{ uploadProgress.total }}</span
      >
      <span class="ph-upload-name">{{ uploadProgress.name }}</span>
      <span class="ph-upload-pct">{{
        uploadProgress.converting
          ? 'converting…'
          : uploadProgress.processing
            ? 'processing…'
            : uploadProgress.pct + '%'
      }}</span>
      <div class="ph-upload-bar">
        <div
          class="ph-upload-bar-fill"
          :style="{ width: uploadProgress.pct + '%' }"
        ></div>
      </div>
    </div>
    <div v-if="uploadErrors.length" class="ph-upload-errors" role="alert">
      <div v-for="(err, i) in uploadErrors" :key="i" class="ph-upload-error">
        {{ err }}
      </div>
      <button class="ph-upload-dismiss" @click="uploadErrors = []">
        Dismiss
      </button>
    </div>

    <div class="ph-scroll">
      <template v-for="g in groups" :key="g.key">
        <div v-if="g.label" class="ph-group-header">
          <span class="ph-group-label">{{ g.label }}</span>
          <span class="ph-group-count">{{ g.photos.length }}</span>
        </div>
        <div class="ph-grid">
          <div
            v-for="p in g.photos"
            :key="p.id"
            class="ph-thumb"
            :class="{
              'ph-thumb--selected': selectionMode && selectedIds.has(p.id)
            }"
            @click="onThumbClick(p, $event)"
          >
            <span
              v-if="selectionMode"
              class="ph-check"
              :class="{ 'ph-check--on': selectedIds.has(p.id) }"
            ></span>
            <button
              v-else
              class="ph-thumb-delete"
              title="Delete"
              aria-label="Delete"
              @click.stop="deletePhotos([p.id])"
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M3 6h18" />
                <path d="M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
                <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
                <path d="M10 11v6M14 11v6" />
              </svg>
            </button>
            <img
              v-if="!broken.has(p.id) && hasGridImage(p)"
              class="ph-thumb-img"
              :src="getThumbPath(p)"
              :alt="p.title || ''"
              loading="lazy"
              @error="broken.add(p.id)"
            />
            <span
              v-if="isVideo(p) && !broken.has(p.id)"
              class="ph-thumb-play"
              aria-hidden="true"
            >
              <svg
                width="34"
                height="34"
                viewBox="0 0 24 24"
                fill="currentColor"
              >
                <circle cx="12" cy="12" r="11" fill="rgba(0, 0, 0, 0.5)" />
                <path d="M10 8l6 4-6 4z" fill="#fff" />
              </svg>
            </span>
            <div v-if="broken.has(p.id)" class="ph-broken">
              <svg
                width="28"
                height="28"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <circle cx="8.5" cy="8.5" r="1.5" />
                <path d="m21 15-5-5L5 21" />
              </svg>
            </div>
            <div
              v-if="getTags(p).length || getPeople(p).length"
              class="ph-thumb-tags"
            >
              <span
                v-for="t in getTags(p)"
                :key="'t' + t"
                class="ph-thumb-tag"
                >{{ t }}</span
              >
              <span
                v-for="pp in getPeople(p)"
                :key="'pp' + pp.id"
                class="ph-thumb-tag ph-thumb-tag--person"
                :title="pp.name"
                >{{ firstName(pp.name) }}</span
              >
            </div>
          </div>
        </div>
      </template>
      <div v-if="filtered.length === 0" class="ph-empty">
        <template v-if="allPhotos.length === 0">
          <div class="ph-nosignal" aria-hidden="true">NO SIGNAL</div>
          <p class="ph-empty-hint">
            Drop images or videos anywhere, or use Upload.
          </p>
        </template>
        <p v-else class="ph-empty-hint">No photos match this filter.</p>
      </div>
    </div>
  </div>

  <Teleport to="body">
    <div
      v-if="faceModalActive"
      class="ph-modal-overlay"
      @click.self="faceModalActive = false"
    >
      <div class="ph-modal ph-modal--faces">
        <h3 class="ph-modal-title">Faces</h3>
        <p v-if="!faceRows.length" class="ph-faces-empty">
          No unnamed faces.
          {{
            missingFaces > 0
              ? 'Run "Scan faces" to detect them first.'
              : 'Everyone is tagged.'
          }}
        </p>
        <div
          v-for="(row, i) in faceRows"
          :key="i"
          class="ph-face-row"
          :class="{ 'ph-face-row--done': row.done }"
        >
          <div class="ph-face-chips">
            <FaceChip
              v-for="(f, j) in row.cluster.faces.slice(0, 5)"
              :key="j"
              :src="chipSrc(f.photoId)"
              :box="f.face.box"
            />
          </div>
          <span class="ph-face-count"
            >{{ row.cluster.faces.length }}
            {{ row.cluster.faces.length === 1 ? 'face' : 'faces' }}</span
          >
          <span v-if="row.done" class="ph-face-done">{{ row.done }}</span>
          <template v-else>
            <ComboBox
              class="ph-face-pick"
              v-model="row.assign"
              :options="contactOptions"
            />
            <button
              class="ph-btn ph-btn--primary"
              :disabled="!row.assign || namingCluster"
              @click="nameCluster(row)"
            >
              Tag
            </button>
          </template>
        </div>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="faceModalActive = false">Close</button>
        </div>
      </div>
    </div>
    <div
      v-if="dateModalActive"
      class="ph-modal-overlay"
      @click.self="closeDateModal"
    >
      <div class="ph-modal">
        <h3 class="ph-modal-title">Date taken</h3>
        <div class="ph-modal-section-label">
          Applies to {{ selCount }} selected
          {{ selCount === 1 ? 'photo' : 'photos' }}
        </div>
        <div class="ph-date-row">
          <DateInput
            class="ph-modal-input"
            v-model="dateModalDate"
            @keydown.enter="applyDate"
            @keydown.esc="closeDateModal"
          />
          <input
            class="ph-modal-input"
            type="time"
            v-model="dateModalTime"
            @keydown.enter="applyDate"
            @keydown.esc="closeDateModal"
          />
        </div>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="closeDateModal">Cancel</button>
          <button
            class="ph-btn ph-btn--primary"
            :disabled="!dateModalDate"
            @click="applyDate"
          >
            Apply
          </button>
        </div>
      </div>
    </div>
    <div
      v-if="tagModalActive"
      class="ph-modal-overlay"
      @click.self="closeTagModal"
    >
      <div class="ph-modal">
        <h3 class="ph-modal-title">Tags</h3>
        <template v-if="currentTags.length">
          <div class="ph-modal-section-label">Current tags</div>
          <div class="ph-modal-current-tags">
            <span
              v-for="t in currentTags"
              :key="t"
              class="ph-modal-current-tag"
            >
              {{ t }}
              <span
                class="ph-modal-tag-remove"
                @click.stop="removeTagFromSelected(t)"
                >×</span
              >
            </span>
          </div>
        </template>
        <div class="ph-modal-section-label">Add a tag</div>
        <input
          ref="tagInput"
          class="ph-modal-input"
          type="text"
          placeholder="Tag name..."
          v-model="tagModalQuery"
          @keydown.enter="applyTag(tagModalQuery)"
          @keydown.esc="closeTagModal"
        />
        <div v-if="tagSuggestions.length" class="ph-modal-suggestions">
          <span
            v-for="t in tagSuggestions"
            :key="t"
            class="ph-modal-suggestion"
            @click="applyTag(t)"
            >{{ t }}</span
          >
        </div>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="closeTagModal">Cancel</button>
          <button
            class="ph-btn ph-btn--primary"
            :disabled="!tagModalQuery.trim()"
            @click="applyTag(tagModalQuery)"
          >
            Add
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.ph-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.ph-layout {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 4rem);
}
.ph-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--border);
  gap: 0.5rem;
}
.ph-filters {
  display: flex;
  gap: 0.5rem;
  align-items: center;
}
.ph-album-filter {
  width: auto;
  min-width: 180px;
}
.ph-sel-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  letter-spacing: 0.06em;
  color: var(--primary);
}
.ph-status {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  color: var(--text);
  white-space: nowrap;
}
.ph-status-unit {
  color: var(--text-muted);
  letter-spacing: 0.08em;
}
.ph-actions {
  display: flex;
  gap: 0.375rem;
  flex-shrink: 0;
}
.ph-btn {
  display: inline-flex;
  align-items: center;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.4rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.85rem;
  white-space: nowrap;
}
.ph-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.ph-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.ph-btn:disabled:hover {
  border-color: var(--border);
  color: var(--text-muted);
}
.ph-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.ph-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}
.ph-btn--danger {
  color: var(--danger);
  border-color: var(--danger);
}
.ph-btn--danger:hover {
  background: rgba(240, 108, 108, 0.08);
}
.ph-tags-bar {
  display: flex;
  gap: 0.375rem;
  padding: 0.5rem 1rem;
  border-bottom: 1px solid var(--border);
  overflow-x: auto;
  flex-shrink: 0;
}
.ph-tag-pill {
  padding: 0.2rem 0.6rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--bg-hover);
  color: var(--text-muted);
  cursor: pointer;
  white-space: nowrap;
  transition:
    background 0.1s,
    color 0.1s;
}
.ph-tag-pill:hover {
  color: var(--text);
}
.ph-tag-pill--active {
  background: var(--primary);
  color: var(--primary-contrast);
}
.ph-people-search {
  padding: 0.5rem 1rem;
  border-bottom: 1px solid var(--border);
  position: relative;
}
.ph-people-input {
  width: 100%;
}
.ph-people-results {
  position: absolute;
  top: 100%;
  left: 1rem;
  right: 1rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  max-height: 240px;
  overflow-y: auto;
  z-index: 10;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
}
.ph-people-result {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.5rem 0.75rem;
  cursor: pointer;
  transition: background 0.1s;
}
.ph-people-result:hover {
  background: var(--bg-hover);
}
.ph-people-avatar {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  object-fit: cover;
  flex-shrink: 0;
}
.ph-people-avatar--init {
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  font-size: 0.7rem;
  font-weight: 600;
}
.ph-people-no-results {
  padding: 0.75rem;
  color: var(--text-muted);
  font-size: 0.85rem;
  text-align: center;
}
.ph-tag-sep {
  width: 1px;
  height: 16px;
  background: var(--border);
  flex-shrink: 0;
  align-self: center;
}
.ph-tag-pill--person {
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
}
.ph-tag-pill--person.ph-tag-pill--active {
  background: #6ccec9;
  color: #000;
}
.ph-thumb-tag--person {
  background: rgba(108, 206, 201, 0.7);
}
.ph-uploading {
  display: flex;
  flex-wrap: wrap; /* the bar takes its own full row: label changes can't resize it */
  align-items: center;
  gap: 0.35rem 0.75rem;
  padding: 0.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.82rem;
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.08);
}
.ph-upload-count {
  letter-spacing: 0.08em;
  flex-shrink: 0;
}
.ph-upload-name {
  color: var(--text-muted);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ph-upload-pct {
  flex-shrink: 0;
  margin-left: auto;
  text-align: right;
}
.ph-upload-bar {
  flex-basis: 100%;
  height: 6px;
  border-radius: 3px;
  background: rgba(var(--primary-rgb), 0.15);
  overflow: hidden;
}
.ph-upload-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 3px;
  transition: width 0.15s;
}
.ph-upload-errors {
  padding: 0.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.82rem;
  color: var(--danger);
  background: rgba(255, 92, 122, 0.08);
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}
.ph-upload-dismiss {
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
.ph-upload-dismiss:hover {
  background: var(--danger);
  color: var(--primary-contrast);
}
.ph-scroll {
  flex: 1;
  overflow-y: auto;
  padding: 0.75rem;
}
.ph-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 0.5rem;
  align-content: start;
  margin-bottom: 1rem;
}
.ph-grid:last-of-type {
  margin-bottom: 0;
}
.ph-group-header {
  position: sticky;
  top: -0.75rem; /* cancel .ph-scroll padding so it pins to the very top */
  z-index: 3;
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.5rem 0 0.45rem;
  margin: 0 -0.1rem 0.5rem;
  background: var(--bg);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
}
.ph-group-header::after {
  content: '';
  flex: 1;
  border-top: 1px solid var(--border);
}
.ph-group-label {
  color: var(--text);
}
.ph-group-count {
  color: var(--text-muted);
}
.ph-thumb {
  position: relative;
  aspect-ratio: 1;
  border-radius: 8px;
  overflow: hidden;
  cursor: pointer;
  background: var(--bg-surface);
  transition: box-shadow 0.15s;
}
.ph-thumb-play {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
}
/* Photos are the light: on hover the image brightens inside a phosphor ring */
.ph-thumb:hover {
  box-shadow:
    0 0 0 2px rgba(var(--primary-rgb), 0.7),
    0 0 14px rgba(var(--primary-rgb), 0.25);
}
.ph-thumb--selected {
  box-shadow:
    0 0 0 2px var(--primary),
    0 0 14px rgba(var(--primary-rgb), 0.35);
}
.ph-thumb img,
.ph-thumb video {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  transition: filter 0.15s;
}
.ph-thumb:hover img,
.ph-thumb:hover video {
  filter: brightness(1.12);
}
.ph-thumb-delete {
  position: absolute;
  top: 6px;
  right: 6px;
  z-index: 2;
  width: 28px;
  height: 28px;
  padding: 0;
  display: grid;
  place-items: center;
  border: 1px solid rgba(255, 255, 255, 0.25);
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.55);
  backdrop-filter: blur(4px);
  color: #fff;
  cursor: pointer;
  opacity: 0;
  transform: scale(0.85);
  transition:
    opacity 0.15s,
    transform 0.15s,
    background 0.15s;
}
.ph-thumb:hover .ph-thumb-delete,
.ph-thumb-delete:focus-visible {
  opacity: 1;
  transform: scale(1);
}
.ph-thumb-delete:hover,
.ph-thumb-delete:focus-visible {
  background: var(--danger);
  border-color: transparent;
}
/* No hover on touch screens: keep the button reachable */
@media (hover: none) {
  .ph-thumb-delete {
    opacity: 1;
    transform: scale(1);
  }
}
.ph-check {
  position: absolute;
  top: 6px;
  left: 6px;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 2px solid rgba(255, 255, 255, 0.6);
  background: rgba(0, 0, 0, 0.3);
  z-index: 2;
  pointer-events: none;
}
.ph-check--on {
  background: var(--primary);
  border-color: var(--primary);
}
.ph-check--on::after {
  content: '';
  position: absolute;
  top: 4px;
  left: 6px;
  width: 5px;
  height: 9px;
  border: solid #fff;
  border-width: 0 2px 2px 0;
  transform: rotate(45deg);
}
.ph-thumb-tags {
  position: absolute;
  bottom: 4px;
  left: 4px;
  right: 4px;
  display: flex;
  gap: 3px;
  flex-wrap: wrap;
  z-index: 1;
}
.ph-thumb-tag {
  font-size: 0.65rem;
  padding: 0.1rem 0.4rem;
  background: rgba(0, 0, 0, 0.6);
  color: #fff;
  border-radius: 4px;
  white-space: nowrap;
}
.ph-layout.ph-dragover {
  outline: 2px dashed var(--primary);
  outline-offset: -4px;
  background: rgba(var(--primary-rgb), 0.05);
}
.ph-broken {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-muted);
  opacity: 0.4;
  background: var(--bg-hover);
}
.ph-empty {
  color: var(--text-muted);
  text-align: center;
  padding: 4rem 1rem;
  grid-column: 1 / -1;
}
.ph-nosignal {
  font-family: var(--font-display);
  font-size: 2.4rem;
  letter-spacing: 0.18em;
  color: var(--primary);
  text-shadow: 0 0 14px rgba(var(--primary-rgb), 0.5);
  margin-bottom: 0.5rem;
}
.ph-empty-hint {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}
.ph-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.ph-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  width: 100%;
  max-width: 360px;
}
.ph-modal-title {
  margin: 0 0 1rem;
  font-size: 1.1rem;
}
.ph-modal-input {
  width: 100%;
  margin-bottom: 0.75rem;
}
.ph-date-row {
  display: flex;
  gap: 0.5rem;
}
.ph-modal--faces {
  max-width: 620px;
  max-height: 80vh;
  overflow-y: auto;
}
.ph-faces-empty {
  color: var(--text-muted);
  font-size: 0.88rem;
}
.ph-face-row {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.6rem 0;
  border-bottom: 1px solid var(--border);
}
.ph-face-row:last-of-type {
  border-bottom: none;
  margin-bottom: 0.5rem;
}
.ph-face-row--done {
  opacity: 0.55;
}
.ph-face-chips {
  display: flex;
  gap: 4px;
  flex-shrink: 1;
  min-width: 0;
  overflow: hidden;
}
.ph-face-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.ph-face-pick {
  margin-left: auto;
  width: 180px;
  flex-shrink: 0;
}
.ph-face-done {
  margin-left: auto;
  color: var(--primary);
  font-size: 0.85rem;
}
.ph-modal-suggestions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin-bottom: 1rem;
}
.ph-modal-suggestion {
  padding: 0.2rem 0.6rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--bg-hover);
  color: var(--text-muted);
  cursor: pointer;
  transition:
    background 0.1s,
    color 0.1s;
}
.ph-modal-suggestion:hover {
  background: var(--primary);
  color: var(--primary-contrast);
}
.ph-modal-section-label {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.03em;
  margin-bottom: 0.4rem;
}
.ph-modal-current-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin-bottom: 1rem;
}
.ph-modal-current-tag {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.2rem 0.5rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--primary);
  color: var(--primary-contrast);
}
.ph-modal-tag-remove {
  cursor: pointer;
  font-size: 1rem;
  line-height: 1;
  opacity: 0.7;
  transition: opacity 0.1s;
}
.ph-modal-tag-remove:hover {
  opacity: 1;
}
.ph-modal-actions {
  display: flex;
  gap: 0.5rem;
  justify-content: flex-end;
}
</style>
