<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'

import ComboBox from '../../components/ComboBox.vue'
import DateInput from '../../components/DateInput.vue'
import FaceChip from './FaceChip.vue'

import { contactInitials, contactName } from '../../lib/contact'
import {
  formatDate,
  formatDateTime,
  utcToZonedParts,
  zonedToUtcISO
} from '../../lib/datetime'
import { openDialog } from '../../lib/dialog'
import { formatFileSize } from '../../lib/filesize'
import {
  clusterFaces,
  facesOf,
  namedReferences,
  type FaceCluster
} from './faces'
import {
  FLAW_LABELS,
  flawsOf,
  measureImage,
  type QualityMetrics
} from './quality'
import {
  batchesDone,
  captureVideoFrame,
  enqueueUploads,
  lastCreated,
  uploadErrors,
  uploadProgress,
  uploading
} from './uploadQueue'
import { preferenceRef } from '../preference'
import type { AppContext, Entry } from '../types'
import type { PhotoShare } from '../../types'

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
// The long backfill loops and scan loops read this flag. They stop when the
// app is unmounted (the user navigates away) and do not continue in the
// background.
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

function field(photo: Entry, key: string): unknown {
  return photo.data[key]
}
const getThumbPath = (photo: Entry) =>
  (field(photo, 'thumb_path') || field(photo, 'path')) as string
const isVideo = (photo: Entry) =>
  ((field(photo, 'mime_type') as string) || '').startsWith('video/')

// Videos never mount a <video> in the grid: one media decoder for each cell
// blocks the browser on large libraries. They show the JPEG frame captured
// at upload time (thumb_path), or a plain play tile when there is none.
const hasGridImage = (photo: Entry) =>
  !isVideo(photo) || !!field(photo, 'thumb_path')
const getTags = (photo: Entry): string[] => (photo.data.tags as string[]) || []
const getPeople = (photo: Entry): Person[] =>
  (photo.data.people as Person[]) || []

const albums = computed(() => {
  const set = new Set<string>()
  for (const photo of allPhotos.value) {
    const a = field(photo, 'album') as string
    if (a) set.add(a)
  }
  return Array.from(set).sort()
})

const allTags = computed(() => {
  const set = new Set<string>()
  for (const photo of allPhotos.value)
    for (const t of getTags(photo)) set.add(t)
  return Array.from(set).sort()
})

const allPeople = computed<Person[]>(() => {
  const map = new Map<string, string>()
  for (const photo of allPhotos.value)
    for (const person of getPeople(photo)) map.set(person.id, person.name)
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name))
})

const filtered = computed(() => {
  let list = allPhotos.value
  if (albumFilter.value)
    list = list.filter(photo => field(photo, 'album') === albumFilter.value)
  if (tagFilter.value)
    list = list.filter(photo => getTags(photo).includes(tagFilter.value))
  if (peopleFilter.value)
    list = list.filter(photo =>
      getPeople(photo).some(pp => pp.id === peopleFilter.value)
    )
  return list
})

// ----- grouping by shot date (occurred_at: the EXIF date, else the upload date) -----

type GroupBy = '' | 'year' | 'month' | 'week'
const groupBy = preferenceRef<GroupBy>(props.ctx, 'photos.groupBy', '')

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
}

const photoDate = (photo: Entry) =>
  (photo.occurred_at || photo.inserted_at) as string

// The thumb chips are very small: they show only the first name. The full
// name stays in the title tooltip, the filter bar and the viewer meta.
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

  for (const photo of list) {
    const iso = photoDate(photo)
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
    out[i].photos.push(photo)
  }
  return out
})

const selCount = computed(() => selectedIds.value.size)

// ----- preview backfill (thumbnails/display JPEGs missing on old entries) -----

const rebuilding = ref(false)
const missingPreviews = computed(
  () =>
    allPhotos.value.filter(
      photo =>
        !isVideo(photo) && (!photo.data.thumb_path || !photo.data.display_path)
    ).length
)

async function rebuildPreviews() {
  rebuilding.value = true
  try {
    await props.ctx.api.fetch('/api/entries/backfill_media', { method: 'POST' })
    // The server regenerates the previews in the background. Poll until no
    // preview is missing, for a maximum of approximately 1 minute.
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
    allPhotos.value.filter(
      photo => isVideo(photo) && !field(photo, 'thumb_path')
    ).length
)
const fixingVideos = ref<{ done: number; total: number } | null>(null)

// Downloads each video, captures a frame in the browser and stores it as the
// thumb_path of the entry. This is the same pipeline as for new uploads.
async function rebuildVideoThumbs() {
  const targets = allPhotos.value.filter(
    photo => isVideo(photo) && !field(photo, 'thumb_path')
  )
  if (!targets.length || fixingVideos.value) return
  fixingVideos.value = { done: 0, total: targets.length }
  for (const photo of targets) {
    if (!alive) break
    try {
      const path = field(photo, 'path') as string
      if (!path) throw new Error('no file path')
      const res = await fetch(path)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const blob = await res.blob()
      const name = (field(photo, 'filename') as string) || 'video'
      const frame = await captureVideoFrame(
        new File([blob], name, {
          type: (field(photo, 'mime_type') as string) || blob.type
        })
      )
      if (!frame) throw new Error("browser can't decode this video")
      const t = (await props.ctx.api.upload(
        frame,
        'photos'
      )) as unknown as Record<string, unknown>
      await props.ctx.api.entries.update(photo.id, {
        data: { ...photo.data, thumb_path: t.path }
      })
    } catch (err) {
      uploadErrors.value.push(
        `${field(photo, 'filename') || 'video'}: ${err instanceof Error ? err.message : 'thumbnail failed'}`
      )
    } finally {
      if (fixingVideos.value) fixingVideos.value.done++
    }
  }
  fixingVideos.value = null
  await reload()
}

// ----- face detection (browser-side, see faceScan.ts) -----

// Returns the image that the detector can decode. This is the 1920px display
// JPEG when it exists. If not, it is the original, for the formats that the
// browser can read. For a HEIC original without a display JPEG, "Fix
// previews" is necessary first.
function faceScanSrc(photo: Entry): string | null {
  if (isVideo(photo)) return null
  const display = field(photo, 'display_path') as string
  if (display) return display
  const mime = ((field(photo, 'mime_type') as string) || '').toLowerCase()
  const path = field(photo, 'path') as string
  if (path && mime.startsWith('image/') && !mime.includes('hei')) return path
  return null
}

const missingFaces = computed(
  () =>
    allPhotos.value.filter(
      photo => !('faces' in photo.data) && faceScanSrc(photo)
    ).length
)
const anyFaces = computed(() =>
  allPhotos.value.some(photo => facesOf(photo).length)
)
const scanningFaces = ref<{ done: number; total: number } | null>(null)

async function scanFaces() {
  const targets = allPhotos.value.filter(
    photo => !('faces' in photo.data) && faceScanSrc(photo)
  )
  if (!targets.length || scanningFaces.value) return
  scanningFaces.value = { done: 0, total: targets.length }
  const { detectFaces } = await import('./faceScan')
  for (const photo of targets) {
    if (!alive) break
    try {
      const faces = await detectFaces(faceScanSrc(photo)!)
      const updated = await props.ctx.api.entries.update(photo.id, {
        data: { ...photo.data, faces }
      })
      allPhotos.value = allPhotos.value.map(item =>
        item.id === updated.id ? updated : item
      )
    } catch (err) {
      uploadErrors.value.push(
        `${field(photo, 'filename') || 'photo'}: ${
          err instanceof Error ? err.message : 'face scan failed'
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
  // The faces excluded from the tag operation ("<photoId>:<index>"). A wrong
  // match in the group stays unnamed and shows again at the next scan.
  excluded: string[]
  done?: string // the contact name, after the tag operation
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

const photoById = computed(
  () => new Map(allPhotos.value.map(photo => [photo.id, photo]))
)
function chipSrc(photoId: string): string {
  const photo = photoById.value.get(photoId)
  return photo ? getThumbPath(photo) : ''
}

const faceKey = (face: FaceCluster['faces'][number]) =>
  `${face.photoId}:${face.index}`

// The face lists of each row, with their exclusion state. The computed
// derives them one time for each change, not for each chip in the template.
const faceRowViews = computed(() =>
  faceRows.value.map(row => {
    const excluded = new Set(row.excluded)
    const faces = row.cluster.faces.map(face => ({
      face,
      key: faceKey(face),
      excluded: excluded.has(faceKey(face)),
      title: photoById.value.get(face.photoId)?.title || 'Photo'
    }))
    const kept = faces.filter(item => !item.excluded).length
    return { row, faces, kept, excludedCount: faces.length - kept }
  })
)

function toggleFaceExcluded(row: ClusterRow, key: string) {
  row.excluded = row.excluded.includes(key)
    ? row.excluded.filter(item => item !== key)
    : [...row.excluded, key]
}

function openFaceModal() {
  faceRows.value = clusterFaces(
    allPhotos.value,
    namedReferences(allPhotos.value)
  ).map(c => ({
    cluster: c,
    assign: c.suggestedPersonId || '',
    excluded: []
  }))
  faceModalActive.value = true
}

// Tags every photo of the cluster with the selected contact (through the
// regular people mechanism) and pins the person on each face. As a result,
// each face becomes a reference for future suggestions.
async function nameCluster(row: ClusterRow) {
  const contact = allContacts.value.find(c => c.id === row.assign)
  if (!contact || row.done || namingCluster.value) return
  namingCluster.value = true
  const name = contactName(contact)
  try {
    const byPhoto = new Map<string, number[]>()
    for (const r of row.cluster.faces) {
      if (row.excluded.includes(faceKey(r))) continue
      byPhoto.set(r.photoId, [...(byPhoto.get(r.photoId) || []), r.index])
    }
    if (!byPhoto.size) return
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
      allPhotos.value = allPhotos.value.map(item =>
        item.id === updated.id ? updated : item
      )
    }
    row.done = name
  } catch (err) {
    uploadErrors.value.push(
      `tagging failed: ${err instanceof Error ? err.message : 'unknown error'}`
    )
  } finally {
    namingCluster.value = false
  }
}

// ----- failed shots (blurry, dark, overexposed) -----

// The app measures the metrics one time for each photo and stores them on
// the photo. `ok` records the "Keep" of the user, which permanently removes
// the photo from the list.
type StoredQuality = QualityMetrics & { ok?: boolean }

const qualityOf = (photo: Entry) =>
  photo.data.quality as StoredQuality | undefined

// The thumbnail is sufficient to judge a shot and is the cheapest image to
// decode.
const qualitySrc = (photo: Entry) =>
  (field(photo, 'thumb_path') as string) || faceScanSrc(photo)

const qualityModalActive = ref(false)
const checkingQuality = ref<{ done: number; total: number } | null>(null)
const qualityUnreadable = ref(0)

const failedShots = computed(() =>
  allPhotos.value.flatMap(photo => {
    const quality = qualityOf(photo)
    if (!quality || quality.ok) return []
    const flaws = flawsOf(quality)
    if (!flaws.length) return []
    return [
      {
        photo,
        flaws: flaws.map(flaw => FLAW_LABELS[flaw]),
        title: photo.title || (field(photo, 'filename') as string) || 'Photo',
        thumb: getThumbPath(photo)
      }
    ]
  })
)

async function openQualityModal() {
  qualityModalActive.value = true
  await checkQuality()
}

async function checkQuality() {
  const targets = allPhotos.value.filter(
    photo => !qualityOf(photo) && qualitySrc(photo)
  )
  if (!targets.length || checkingQuality.value) return
  checkingQuality.value = { done: 0, total: targets.length }
  qualityUnreadable.value = 0
  for (const photo of targets) {
    if (!alive || !qualityModalActive.value) break
    try {
      const quality = await measureImage(qualitySrc(photo)!)
      const updated = await props.ctx.api.entries.update(photo.id, {
        data: { ...photo.data, quality }
      })
      allPhotos.value = allPhotos.value.map(item =>
        item.id === updated.id ? updated : item
      )
    } catch {
      // ponytail: the next check tries an unreadable photo again. Store a
      // marker if a large backlog of broken photos makes that slow.
      qualityUnreadable.value++
    } finally {
      if (checkingQuality.value) checkingQuality.value.done++
    }
  }
  checkingQuality.value = null
}

// The note goes with the photo, also into the public share feed.
async function saveNote(id: string, note: string) {
  const photo = photoById.value.get(id)
  if (!photo) return
  try {
    const updated = await props.ctx.api.entries.update(id, {
      data: { ...photo.data, note: note || null }
    })
    allPhotos.value = allPhotos.value.map(item =>
      item.id === updated.id ? updated : item
    )
  } catch (err) {
    uploadErrors.value.push(
      `note: ${err instanceof Error ? err.message : 'save failed'}`
    )
  }
}

async function keepShot(photo: Entry) {
  try {
    const updated = await props.ctx.api.entries.update(photo.id, {
      data: { ...photo.data, quality: { ...qualityOf(photo)!, ok: true } }
    })
    allPhotos.value = allPhotos.value.map(item =>
      item.id === updated.id ? updated : item
    )
  } catch (err) {
    uploadErrors.value.push(
      `${field(photo, 'filename') || 'photo'}: ${
        err instanceof Error ? err.message : 'update failed'
      }`
    )
  }
}

const hasFilters = computed(
  () => allTags.value.length > 0 || allPeople.value.length > 0
)

const matchingContacts = computed(() => {
  if (!peopleSearchActive.value) return []
  const q = peopleSearchQuery.value.toLowerCase()
  if (!q) {
    // Before the user types, offer the people who are tagged on other photos.
    // The user then gets the recurring people with one click, without a
    // search.
    return allPeople.value
      .map(photo => allContacts.value.find(c => c.id === photo.id))
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
    const photo = allPhotos.value.find(photo => photo.id === id)
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

// ----- share links (public photo feeds over tags and people) -----

const shareModalActive = ref(false)
const shares = ref<PhotoShare[]>([])
const shareTags = ref<string[]>([])
const sharePeople = ref<Person[]>([])
const shareMatch = ref<'any' | 'all'>('any')
const shareName = ref('')
const shareBusy = ref(false)
const shareError = ref('')
const copiedShareId = ref('')
let copiedTimer: ReturnType<typeof setTimeout> | undefined

const SHARE_MATCH_OPTIONS = [
  { value: 'any', label: 'Photos with any of these' },
  { value: 'all', label: 'Photos with all of these' }
]

const shareCriteriaCount = computed(
  () => shareTags.value.length + sharePeople.value.length
)
const sharePeopleIds = computed(
  () => new Set(sharePeople.value.map(person => person.id))
)

const shareRows = computed(() =>
  shares.value.map(share => ({
    share,
    label:
      share.name ||
      [
        ...share.tags.map(tag => `#${tag}`),
        ...(share.people || []).map(person => person.name)
      ].join(share.match === 'all' ? ' + ' : ', '),
    url: new URL(share.path, window.location.origin).toString()
  }))
)

async function shareRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await props.ctx.api.fetch(path, init)
  if (res.status === 204) return undefined as T
  return (await res.json()).data as T
}

async function openShareModal() {
  shareTags.value = tagFilter.value ? [tagFilter.value] : []
  sharePeople.value = allPeople.value.filter(
    person => person.id === peopleFilter.value
  )
  shareMatch.value = 'any'
  shareName.value = ''
  shareError.value = ''
  shareModalActive.value = true
  try {
    shares.value = await shareRequest<PhotoShare[]>('/api/photo_shares')
  } catch (err) {
    shareError.value =
      err instanceof Error ? err.message : 'Failed to load the links'
  }
}
function closeShareModal() {
  shareModalActive.value = false
}
function toggleShareTag(tag: string) {
  shareTags.value = shareTags.value.includes(tag)
    ? shareTags.value.filter(selected => selected !== tag)
    : [...shareTags.value, tag]
}
function toggleSharePerson(person: Person) {
  sharePeople.value = sharePeopleIds.value.has(person.id)
    ? sharePeople.value.filter(selected => selected.id !== person.id)
    : [...sharePeople.value, person]
}
function onShareMatchChange(value: string) {
  shareMatch.value = value === 'all' ? 'all' : 'any'
}
async function createShare() {
  if (!shareCriteriaCount.value || shareBusy.value) return
  shareBusy.value = true
  shareError.value = ''
  try {
    const share = await shareRequest<PhotoShare>('/api/photo_shares', {
      method: 'POST',
      body: JSON.stringify({
        name: shareName.value.trim() || null,
        tags: shareTags.value,
        people: sharePeople.value,
        match: shareMatch.value
      })
    })
    shares.value = [share, ...shares.value]
    shareName.value = ''
    await copyShare(share)
  } catch (err) {
    shareError.value =
      err instanceof Error ? err.message : 'Failed to create the link'
  } finally {
    shareBusy.value = false
  }
}
async function copyShare(share: PhotoShare) {
  const url = new URL(share.path, window.location.origin).toString()
  try {
    await navigator.clipboard.writeText(url)
    copiedShareId.value = share.id
    clearTimeout(copiedTimer)
    copiedTimer = setTimeout(() => (copiedShareId.value = ''), 2000)
  } catch {
    // There is no clipboard access (insecure context). The user can still
    // select the URL.
  }
}
async function revokeShare(share: PhotoShare) {
  const ok = await props.ctx.confirm.ask({
    message: 'Revoke this link? Anyone holding it loses access at once.',
    confirmLabel: 'Revoke',
    danger: true
  })
  if (!ok) return
  shareError.value = ''
  try {
    await shareRequest<void>(`/api/photo_shares/${share.id}`, {
      method: 'DELETE'
    })
    shares.value = shares.value.filter(existing => existing.id !== share.id)
  } catch (err) {
    shareError.value =
      err instanceof Error ? err.message : 'Failed to revoke the link'
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
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load photos'
  } finally {
    loading.value = false
  }
}

// The upload state and the upload pipeline are in ./uploadQueue (module
// scope). As a result, a batch continues when the user navigates to another
// app during the upload. While the app is mounted, the created photos go
// into the grid in batches of 1s. There is one regroup and one re-render for
// each flush, not for each upload: for each upload, a batch of 500 files
// renders the grid 500 times. When the queue becomes empty, one reload makes
// all the data correct.
let pendingCreated: Entry[] = []
let createdFlushTimer: ReturnType<typeof setTimeout> | undefined

function flushCreated() {
  createdFlushTimer = undefined
  const fresh = pendingCreated.filter(
    c => !allPhotos.value.some(photo => photo.id === c.id)
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

function onFileInput(event: Event) {
  const input = event.target as HTMLInputElement
  if (input.files?.length) uploadFiles(Array.from(input.files))
  // Reset the input. Then the change event fires again when the user selects
  // the same file or files again.
  input.value = ''
}
const dragover = ref(false)
function onDrop(event: DragEvent) {
  dragover.value = false
  if (event.dataTransfer?.files.length)
    uploadFiles(Array.from(event.dataTransfer.files))
}

// The anchor for the range selection with shift-click: the last photo clicked
// in select mode.
let lastClickedId: string | null = null

function onThumbClick(photo: Entry, event?: MouseEvent) {
  if (selectionMode.value) {
    // Shift extends the selection from the anchor to the clicked photo, in
    // grid order.
    if (event?.shiftKey && lastClickedId && lastClickedId !== photo.id) {
      const list = filtered.value
      const from = list.findIndex(item => item.id === lastClickedId)
      const to = list.findIndex(item => item.id === photo.id)
      if (from !== -1 && to !== -1) {
        const [lo, hi] = from < to ? [from, to] : [to, from]
        for (let i = lo; i <= hi; i++) selectedIds.value.add(list[i].id)
        lastClickedId = photo.id
        return
      }
    }
    if (selectedIds.value.has(photo.id)) selectedIds.value.delete(photo.id)
    else selectedIds.value.add(photo.id)
    lastClickedId = photo.id
  } else if (event?.shiftKey) {
    // A shift-click in browse mode goes directly into selection mode.
    selectionMode.value = true
    selectedIds.value.add(photo.id)
    lastClickedId = photo.id
  } else {
    openViewer(photo.id)
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
  for (const photo of filtered.value) selectedIds.value.add(photo.id)
}
function deselect() {
  selectedIds.value.clear()
}

async function deletePhotos(ids: string[]) {
  if (!ids.length) return
  const single =
    ids.length === 1
      ? allPhotos.value.find(photo => photo.id === ids[0])
      : undefined
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
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : 'Delete failed'
  }
  selectedIds.value.clear()
  selectionMode.value = false
  await reload()
}

// The rotation keeps the selection. To correct an orientation, a second
// quarter turn is often necessary, and the user must not have to select the
// photos again.
const rotating = ref(false)
async function rotateSelected(angle: 90 | 270) {
  const targets = [...selectedIds.value]
    .map(id => allPhotos.value.find(photo => photo.id === id))
    .filter((photo): photo is Entry => !!photo && !isVideo(photo))
  if (!targets.length || rotating.value) return
  rotating.value = true
  try {
    for (const photo of targets) {
      try {
        await props.ctx.api.fetch(
          `/api/entries/${photo.id}/rotate_photo?angle=${angle}`,
          { method: 'POST' }
        )
      } catch (err) {
        uploadErrors.value.push(
          `${(photo.data.filename as string) || photo.title || photo.id}: ${
            err instanceof Error ? err.message : 'rotation failed'
          }`
        )
      }
    }
    await reload()
  } finally {
    rotating.value = false
  }
}

// ponytail: sets only occurred_at and data.date_taken. The code does not
// rewrite the EXIF bytes in the file (for that, exiftool or a lossy vips
// re-encode is necessary).
const dateModalActive = ref(false)
const dateModalDate = ref('')
const dateModalTime = ref('')

function openDateModal() {
  const first = allPhotos.value.find(photo => selectedIds.value.has(photo.id))
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
      const photo = allPhotos.value.find(photo => photo.id === id)
      if (!photo) continue
      await props.ctx.api.entries.update(id, {
        occurred_at: iso,
        data: { ...photo.data, date_taken: iso }
      })
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to set the date'
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
function onPeopleKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') {
    peopleSearchActive.value = false
    peopleSearchQuery.value = ''
  }
}
async function tagWithContact(contact: Entry) {
  const name = contactName(contact)
  loadError.value = ''
  try {
    for (const id of selectedIds.value) {
      const photo = allPhotos.value.find(photo => photo.id === id)
      if (!photo) continue
      const existing = getPeople(photo)
      if (existing.some(pp => pp.id === contact.id)) continue
      await props.ctx.api.entries.update(id, {
        data: {
          ...photo.data,
          people: [...existing, { id: contact.id, name }]
        }
      })
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to tag people'
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
      const photo = allPhotos.value.find(photo => photo.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      if (existing.includes(t)) continue
      await props.ctx.api.entries.update(id, {
        data: { ...photo.data, tags: [...existing, t] }
      })
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to add the tag'
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
      const photo = allPhotos.value.find(photo => photo.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      if (!existing.includes(tag)) continue
      await props.ctx.api.entries.update(id, {
        data: { ...photo.data, tags: existing.filter(t => t !== tag) }
      })
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to remove the tag'
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
      const photo = allPhotos.value.find(photo => photo.id === id)
      if (!photo) continue
      const existing = getTags(photo)
      await props.ctx.api.entries.update(id, {
        data: {
          ...photo.data,
          tags: existing.filter(t => t !== tagFilter.value)
        }
      })
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to remove the tag'
  } finally {
    selectedIds.value.clear()
    selectionMode.value = false
    await reload()
  }
}

function openViewer(photoId: string, opts: { push?: boolean } = {}) {
  // When the user opens a photo, the app adds a history entry. As a result,
  // the back button of the browser closes the photo.
  if (opts.push !== false) {
    history.pushState(null, '', `/apps/photos?photo=${photoId}`)
  }
  const photos = filtered.value
  const items = photos.map(photo => {
    const meta: Record<string, string | number | null> = {}
    // Without EXIF, this is the date that the grid sorts by (the file date,
    // else the upload date).
    if (photo.data.date_taken)
      meta['Date taken'] = formatDateTime(photo.data.date_taken as string)
    else meta['Date'] = formatDateTime(photoDate(photo))
    if (photo.data.camera) meta['Camera'] = photo.data.camera as string
    if (photo.data.latitude != null)
      meta['Location'] =
        `${(photo.data.latitude as number).toFixed(5)}, ${(photo.data.longitude as number).toFixed(5)}`
    if (photo.data.size)
      meta['Size'] = formatFileSize(photo.data.size as number)
    if (photo.data.filename) meta['Filename'] = photo.data.filename as string
    if (photo.data.album) meta['Album'] = photo.data.album as string
    const tags = getTags(photo)
    if (tags.length) meta['Tags'] = tags.join(', ')
    const photoPeople = getPeople(photo)
    if (photoPeople.length)
      meta['People'] = photoPeople.map(pp => pp.name).join(', ')
    return {
      id: photo.id,
      // display_path is the fast 1920px JPEG. The original stays one click away.
      src: (field(photo, 'display_path') || field(photo, 'path')) as string,
      fullSrc: field(photo, 'display_path')
        ? (field(photo, 'path') as string)
        : undefined,
      video: isVideo(photo),
      title: photo.title || undefined,
      subtitle: (field(photo, 'album') as string) || undefined,
      meta: Object.keys(meta).length ? meta : undefined,
      note: (field(photo, 'note') as string) || undefined
    }
  })
  const idx = photos.findIndex(photo => photo.id === photoId)
  // The deep-linked photo can be outside the active filter. Do not silently
  // open the first photo (idx -1 -> 0) as if it was the requested photo.
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
  props.ctx.viewer.onNote(saveNote)
  // The backdrop, Esc and Close must also remove the ?photo= deep link.
  props.ctx.viewer.onClose(() => {
    if (new URLSearchParams(window.location.search).get('photo')) {
      history.replaceState(null, '', '/apps/photos')
    }
  })
  await reload()
  const params = new URLSearchParams(window.location.search)
  // A contact card links here with ?person=<contact id> ("all photos of X").
  const person = params.get('person')
  if (person) setFilter({ person })
  const initial = params.get('photo')
  if (initial) openViewer(initial, { push: false })
})
onUnmounted(() => {
  alive = false
  clearTimeout(createdFlushTimer)
  clearTimeout(copiedTimer)
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
          v-for="contact in matchingContacts"
          :key="contact.id"
          class="ph-people-result"
          @click="tagWithContact(contact)"
        >
          <img
            v-if="contact.data.photo"
            class="ph-people-avatar"
            :src="contact.data.photo as string"
            alt=""
          />
          <span v-else class="ph-people-avatar ph-people-avatar--init">{{
            contactInitials(contactName(contact))
          }}</span>
          <span>{{ contactName(contact) }}</span>
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
        <button
          v-if="allPhotos.length"
          class="ph-btn"
          @click="openQualityModal"
        >
          Failed shots
        </button>
        <button
          v-if="allTags.length || allPeople.length"
          class="ph-btn"
          @click="openShareModal"
        >
          Share
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
        v-for="tag in allTags"
        :key="'tag' + tag"
        class="ph-tag-pill"
        :class="{ 'ph-tag-pill--active': tag === tagFilter }"
        @click="setFilter({ tag: tag })"
        >{{ tag }}</span
      >
      <span v-if="allPeople.length" class="ph-tag-sep"></span>
      <span
        v-for="person in allPeople"
        :key="'person' + person.id"
        class="ph-tag-pill ph-tag-pill--person"
        :class="{ 'ph-tag-pill--active': person.id === peopleFilter }"
        :title="person.name"
        @click="setFilter({ person: person.id })"
        >{{ firstName(person.name) }}</span
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
      <div
        v-for="(err, index) in uploadErrors"
        :key="index"
        class="ph-upload-error"
      >
        {{ err }}
      </div>
      <button class="ph-upload-dismiss" @click="uploadErrors = []">
        Dismiss
      </button>
    </div>

    <div class="ph-scroll">
      <template v-for="group in groups" :key="group.key">
        <div v-if="group.label" class="ph-group-header">
          <span class="ph-group-label">{{ group.label }}</span>
          <span class="ph-group-count">{{ group.photos.length }}</span>
        </div>
        <div class="ph-grid">
          <div
            v-for="photo in group.photos"
            :key="photo.id"
            class="ph-thumb"
            :class="{
              'ph-thumb--selected': selectionMode && selectedIds.has(photo.id)
            }"
            @click="onThumbClick(photo, $event)"
          >
            <span
              v-if="selectionMode"
              class="ph-check"
              :class="{ 'ph-check--on': selectedIds.has(photo.id) }"
            ></span>
            <button
              v-else
              class="ph-thumb-delete"
              title="Delete"
              aria-label="Delete"
              @click.stop="deletePhotos([photo.id])"
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
              v-if="!broken.has(photo.id) && hasGridImage(photo)"
              class="ph-thumb-img"
              :src="getThumbPath(photo)"
              :alt="photo.title || ''"
              loading="lazy"
              @error="broken.add(photo.id)"
            />
            <span
              v-if="isVideo(photo) && !broken.has(photo.id)"
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
            <div v-if="broken.has(photo.id)" class="ph-broken">
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
              v-if="getTags(photo).length || getPeople(photo).length"
              class="ph-thumb-tags"
            >
              <span
                v-for="tag in getTags(photo)"
                :key="'tag' + tag"
                class="ph-thumb-tag"
                >{{ tag }}</span
              >
              <span
                v-for="tagged in getPeople(photo)"
                :key="'person' + tagged.id"
                class="ph-thumb-tag ph-thumb-tag--person"
                :title="tagged.name"
                >{{ firstName(tagged.name) }}</span
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
    <dialog
      v-if="faceModalActive"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="ph-faces-title"
      @click.self="faceModalActive = false"
      @cancel="faceModalActive = false"
    >
      <div class="ph-modal ph-modal--faces">
        <h3 id="ph-faces-title" class="ph-modal-title">Faces</h3>
        <p v-if="!faceRows.length" class="ph-faces-empty">
          No unnamed faces.
          {{
            missingFaces > 0
              ? 'Run "Scan faces" to detect them first.'
              : 'Everyone is tagged.'
          }}
        </p>
        <p v-if="faceRows.length" class="ph-faces-help">
          Click a face that does not belong to the group to leave it out; it
          stays unnamed.
        </p>
        <div
          v-for="(view, rowIndex) in faceRowViews"
          :key="rowIndex"
          class="ph-face-row"
          :class="{ 'ph-face-row--done': view.row.done }"
        >
          <div class="ph-face-head">
            <span class="ph-face-count"
              >{{ view.kept }} {{ view.kept === 1 ? 'face' : 'faces'
              }}<template v-if="view.excludedCount">
                ({{ view.excludedCount }} left out)</template
              ></span
            >
            <span v-if="view.row.done" class="ph-face-done">{{
              view.row.done
            }}</span>
            <template v-else>
              <ComboBox
                class="ph-face-pick"
                v-model="view.row.assign"
                :options="contactOptions"
              />
              <button
                class="ph-btn ph-btn--primary"
                :disabled="!view.row.assign || !view.kept || namingCluster"
                @click="nameCluster(view.row)"
              >
                Tag
              </button>
            </template>
          </div>
          <div class="ph-face-chips">
            <button
              v-for="item in view.faces"
              :key="item.key"
              type="button"
              class="ph-face-toggle"
              :class="{ 'ph-face-toggle--out': item.excluded }"
              :aria-pressed="!item.excluded"
              :aria-label="`Face in ${item.title}`"
              :title="
                item.excluded
                  ? `${item.title}: left out, click to include`
                  : `${item.title}: click to leave out`
              "
              :disabled="!!view.row.done"
              @click="toggleFaceExcluded(view.row, item.key)"
            >
              <FaceChip
                :src="chipSrc(item.face.photoId)"
                :box="item.face.face.box"
              />
            </button>
          </div>
        </div>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="faceModalActive = false">Close</button>
        </div>
      </div>
    </dialog>
    <dialog
      v-if="qualityModalActive"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="ph-quality-title"
      @click.self="qualityModalActive = false"
      @cancel="qualityModalActive = false"
    >
      <div class="ph-modal ph-modal--wide">
        <h3 id="ph-quality-title" class="ph-modal-title">Failed shots</h3>
        <p class="ph-faces-help">
          Blurry, too dark or overexposed photos, spotted from their thumbnail.
          Delete them, or keep one to take it off this list for good.
        </p>
        <p v-if="checkingQuality" class="ph-shots-status" role="status">
          Checking photos {{ checkingQuality.done }}/{{
            checkingQuality.total
          }}…
        </p>
        <p v-if="qualityUnreadable" class="ph-shots-status">
          {{ qualityUnreadable }}
          {{ qualityUnreadable === 1 ? 'photo' : 'photos' }} could not be read.
        </p>
        <p
          v-if="!checkingQuality && !failedShots.length"
          class="ph-faces-empty"
        >
          No failed shots.
        </p>
        <ul v-if="failedShots.length" class="ph-shots">
          <li v-for="shot in failedShots" :key="shot.photo.id" class="ph-shot">
            <img
              class="ph-shot-img"
              :src="shot.thumb"
              :alt="shot.title"
              loading="lazy"
            />
            <div class="ph-shot-flaws">
              <span
                v-for="flaw in shot.flaws"
                :key="flaw"
                class="ph-shot-flaw"
                >{{ flaw }}</span
              >
            </div>
            <span class="ph-shot-title" :title="shot.title">{{
              shot.title
            }}</span>
            <div class="ph-shot-actions">
              <button class="ph-btn" @click="keepShot(shot.photo)">Keep</button>
              <button
                class="ph-btn ph-btn--danger"
                @click="deletePhotos([shot.photo.id])"
              >
                Delete
              </button>
            </div>
          </li>
        </ul>
        <div class="ph-modal-actions">
          <button class="ph-btn" autofocus @click="qualityModalActive = false">
            Close
          </button>
        </div>
      </div>
    </dialog>
    <dialog
      v-if="dateModalActive"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="ph-date-title"
      @click.self="closeDateModal"
      @cancel="closeDateModal"
    >
      <div class="ph-modal">
        <h3 id="ph-date-title" class="ph-modal-title">Date taken</h3>
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
    </dialog>
    <dialog
      v-if="tagModalActive"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="ph-tags-title"
      @click.self="closeTagModal"
      @cancel="closeTagModal"
    >
      <div class="ph-modal">
        <h3 id="ph-tags-title" class="ph-modal-title">Tags</h3>
        <template v-if="currentTags.length">
          <div class="ph-modal-section-label">Current tags</div>
          <div class="ph-modal-current-tags">
            <span
              v-for="tag in currentTags"
              :key="tag"
              class="ph-modal-current-tag"
            >
              {{ tag }}
              <span
                class="ph-modal-tag-remove"
                @click.stop="removeTagFromSelected(tag)"
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
            v-for="tag in tagSuggestions"
            :key="tag"
            class="ph-modal-suggestion"
            @click="applyTag(tag)"
            >{{ tag }}</span
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
    </dialog>
    <dialog
      v-if="shareModalActive"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="ph-share-title"
      @click.self="closeShareModal"
      @cancel="closeShareModal"
    >
      <div class="ph-modal ph-modal--share">
        <h3 id="ph-share-title" class="ph-modal-title">Share a photo feed</h3>
        <p class="ph-share-help">
          Anyone with the link sees the photos carrying the tags and people you
          pick, including the ones you tag later. Nothing else is exposed, not
          even the names of the people.
        </p>
        <div v-if="allTags.length" class="ph-modal-section-label">Tags</div>
        <div v-if="allTags.length" class="ph-modal-suggestions">
          <button
            v-for="tag in allTags"
            :key="tag"
            type="button"
            class="ph-modal-suggestion"
            :class="{
              'ph-modal-suggestion--active': shareTags.includes(tag)
            }"
            :aria-pressed="shareTags.includes(tag)"
            @click="toggleShareTag(tag)"
          >
            {{ tag }}
          </button>
        </div>
        <div v-if="allPeople.length" class="ph-modal-section-label">People</div>
        <div v-if="allPeople.length" class="ph-modal-suggestions">
          <button
            v-for="person in allPeople"
            :key="person.id"
            type="button"
            class="ph-modal-suggestion"
            :class="{
              'ph-modal-suggestion--active': sharePeopleIds.has(person.id)
            }"
            :aria-pressed="sharePeopleIds.has(person.id)"
            @click="toggleSharePerson(person)"
          >
            {{ person.name }}
          </button>
        </div>
        <ComboBox
          v-if="shareCriteriaCount > 1"
          class="ph-modal-input"
          :model-value="shareMatch"
          :options="SHARE_MATCH_OPTIONS"
          @update:model-value="onShareMatchChange"
        />
        <input
          class="ph-modal-input"
          type="text"
          placeholder="Link name (optional)"
          aria-label="Link name"
          v-model="shareName"
          @keydown.enter="createShare"
          @keydown.esc="closeShareModal"
        />
        <p v-if="shareError" class="ph-share-error">{{ shareError }}</p>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="closeShareModal">Close</button>
          <button
            class="ph-btn ph-btn--primary"
            :disabled="!shareCriteriaCount || shareBusy"
            autofocus
            @click="createShare"
          >
            {{ shareBusy ? 'Creating…' : 'Create link' }}
          </button>
        </div>
        <template v-if="shareRows.length">
          <div class="ph-modal-section-label ph-share-list-label">
            Existing links
          </div>
          <ul class="ph-share-list">
            <li
              v-for="row in shareRows"
              :key="row.share.id"
              class="ph-share-row"
            >
              <div class="ph-share-info">
                <span class="ph-share-label">{{ row.label }}</span>
                <code class="ph-share-url">{{ row.url }}</code>
              </div>
              <div class="ph-share-row-actions">
                <button class="ph-btn" @click="copyShare(row.share)">
                  {{ copiedShareId === row.share.id ? 'Copied' : 'Copy' }}
                </button>
                <a
                  class="ph-btn"
                  :href="row.share.path"
                  target="_blank"
                  rel="noopener"
                  >Open</a
                >
                <button
                  class="ph-btn ph-btn--danger"
                  @click="revokeShare(row.share)"
                >
                  Revoke
                </button>
              </div>
            </li>
          </ul>
        </template>
      </div>
    </dialog>
  </Teleport>
</template>

<style scoped>
.ph-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: var(--font-mono);
}
.ph-layout {
  display: flex;
  flex-direction: column;
  height: 100vh;
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
  font-family: var(--font-mono);
  font-size: 0.85rem;
  letter-spacing: 0.06em;
  color: var(--primary);
}
.ph-status {
  font-family: var(--font-mono);
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
  flex-wrap: wrap; /* the bar takes its own full row: label changes cannot resize it */
  align-items: center;
  gap: 0.35rem 0.75rem;
  padding: 0.5rem 1rem;
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
  top: -0.75rem; /* cancels the .ph-scroll padding, to pin the header at the top edge */
  z-index: 3;
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.5rem 0 0.45rem;
  margin: 0 -0.1rem 0.5rem;
  background: var(--bg);
  font-family: var(--font-mono);
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
/* Photos are the light: on hover, the image becomes brighter in a phosphor ring */
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
  color: var(--primary-contrast);
}
/* Touch screens have no hover: keep the button reachable */
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
  font-family: var(--font-mono);
  font-size: 0.88rem;
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
  max-width: 1100px;
  max-height: 80vh;
  overflow-y: auto;
}
.ph-modal--wide {
  max-width: 1100px;
  max-height: 85vh;
  overflow-y: auto;
}
.ph-shots-status {
  margin: 0 0 0.75rem;
  font-family: var(--font-mono);
  font-size: 0.8rem;
  color: var(--text-muted);
}
.ph-shots {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
  gap: 0.75rem;
  margin: 0 0 1rem;
  padding: 0;
  list-style: none;
}
.ph-shot {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  min-width: 0;
}
.ph-shot-img {
  width: 100%;
  aspect-ratio: 1;
  object-fit: cover;
  border-radius: 8px;
  background: var(--bg-hover);
}
.ph-shot-flaws {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3rem;
}
.ph-shot-flaw {
  padding: 0.1rem 0.45rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--danger) 12%, transparent);
  color: var(--danger);
  font-family: var(--font-mono);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.ph-shot-title {
  font-size: 0.8rem;
  color: var(--text-muted);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ph-shot-actions {
  display: flex;
  gap: 0.4rem;
}
.ph-shot-actions .ph-btn {
  flex: 1;
}
.ph-modal--share {
  max-width: 560px;
  max-height: 85vh;
  overflow-y: auto;
}
.ph-faces-empty {
  color: var(--text-muted);
  font-size: 0.88rem;
}
.ph-faces-help {
  margin: -0.5rem 0 0.5rem;
  color: var(--text-muted);
  font-size: 0.85rem;
}
.ph-face-row {
  display: flex;
  flex-direction: column;
  gap: 0.6rem;
  padding: 0.9rem 0;
  border-bottom: 1px solid var(--border);
}
.ph-face-row:last-of-type {
  border-bottom: none;
  margin-bottom: 0.5rem;
}
.ph-face-row--done {
  opacity: 0.55;
}
.ph-face-head {
  display: flex;
  align-items: center;
  gap: 0.6rem;
}
.ph-face-count {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.ph-face-pick {
  margin-left: auto;
  width: 220px;
  flex-shrink: 0;
}
.ph-face-done {
  margin-left: auto;
  color: var(--primary);
  font-size: 0.85rem;
}
/* Shows every face of the group, with wrap: the user judges the full set at
   one time. */
.ph-face-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.ph-face-toggle {
  position: relative;
  display: flex;
  padding: 0;
  border: 2px solid transparent;
  border-radius: 10px;
  background: none;
  cursor: pointer;
}
.ph-face-toggle:hover:not(:disabled) {
  border-color: var(--border);
}
.ph-face-toggle:disabled {
  cursor: default;
}
.ph-face-toggle--out {
  opacity: 0.35;
  filter: grayscale(1);
}
.ph-face-toggle--out::after {
  content: '×';
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.8rem;
  color: var(--danger);
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
button.ph-modal-suggestion {
  border: none;
  font: inherit;
  font-size: 0.8rem;
}
.ph-modal-suggestion--active {
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

/* ----- Share modal ----- */
.ph-share-help {
  margin: 0 0 1rem;
  font-size: 0.85rem;
  color: var(--text-muted);
}
.ph-share-error {
  margin: 0 0 0.75rem;
  font-size: 0.85rem;
  color: var(--danger);
}
.ph-share-list-label {
  margin-top: 1.25rem;
  padding-top: 1rem;
  border-top: 1px solid var(--border);
}
.ph-share-list {
  list-style: none;
  margin: 0;
  padding: 0;
}
.ph-share-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  padding: 0.6rem 0;
  border-bottom: 1px solid var(--border);
}
.ph-share-row:last-of-type {
  border-bottom: none;
}
.ph-share-info {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  min-width: 0;
}
.ph-share-label {
  font-size: 0.9rem;
}
.ph-share-url {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  user-select: all;
}
.ph-share-row-actions {
  display: flex;
  gap: 0.375rem;
  flex-shrink: 0;
}
.ph-share-row-actions .ph-btn {
  text-decoration: none;
}
</style>
