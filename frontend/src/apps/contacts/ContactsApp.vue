<script setup lang="ts">
import {
  computed,
  nextTick,
  onMounted,
  onUnmounted,
  reactive,
  ref,
  watch
} from 'vue'
import { useVirtualList } from '@vueuse/core'
import { Cake, User } from 'lucide-vue-next'

import AutocompleteInput from '../../components/AutocompleteInput.vue'
import ComboBox from '../../components/ComboBox.vue'
import DateInput from '../../components/DateInput.vue'
import RelationsGraph from './RelationsGraph.vue'

import { contactField, contactInitials, contactName } from '../../lib/contact'
import { formatDate } from '../../lib/datetime'
import { safeUrl } from '../../lib/url'
// Photos owns the shape of a stored face; read it through its helper rather
// than re-deriving `data.faces` here.
import { facesOf } from '../photos/faces'
import {
  RELATION_TYPES,
  inverseType,
  normalizeRelationType,
  relationLabel,
  relationsOf,
  tagsOf,
  withRelation,
  withoutRelation,
  type Relation
} from './relations'
import type { AppContext, Entry } from '../types'

const props = defineProps<{ ctx: AppContext }>()

interface Labeled {
  value: string
  type: string
}

const allContacts = ref<Entry[]>([])
const searchQuery = ref('')
// Several tags can be active at once, and they narrow: a contact must carry
// all of them. Clicking an active chip drops it again.
const activeTags = ref<string[]>([])
const selectedId = ref<string | null>(
  new URLSearchParams(window.location.search).get('selected')
)
const loading = ref(true)
const loadError = ref('')

// The detail column is the single workplace: it shows the full contact,
// edits it in place, and hosts creation (no modal, no separate page).
const mode = ref<'view' | 'edit' | 'create'>('view')
const saving = ref(false)
const formError = ref('')
const avatarUploading = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)
const searchInput = ref<HTMLInputElement | null>(null)
const form = reactive({
  display_name: '',
  org: '',
  title: '',
  emails: [] as Labeled[],
  phones: [] as Labeled[],
  address: '',
  birthday: '',
  url: '',
  note: '',
  photo: ''
})

const fld = contactField
const getInitials = contactInitials

// Deterministic tint per contact: hash the name into a hue, keep the
// avatar's translucent-bg + tinted-text look.
function avatarStyle(name: string) {
  let h = 0
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360
  return {
    background: `hsla(${h}, 55%, 60%, 0.16)`,
    color: `hsl(${h}, 45%, 62%)`
  }
}
const isUnnamed = (contact: Entry) => contactName(contact) === '(unnamed)'
const getEmails = (contact: Entry) => (contact.data.emails as Labeled[]) || []
const getPhones = (contact: Entry) => (contact.data.phones as Labeled[]) || []

function sortContacts(list: Entry[]): Entry[] {
  return [...list].sort((a, b) => {
    const aUn = isUnnamed(a)
    const bUn = isUnnamed(b)
    if (aUn !== bUn) return aUn ? 1 : -1
    return contactName(a)
      .toLowerCase()
      .localeCompare(contactName(b).toLowerCase())
  })
}

const filtered = computed(() => {
  let list = allContacts.value
  if (activeTags.value.length) {
    list = list.filter(contact => {
      const tags = tagsOf(contact)
      return activeTags.value.every(t => tags.includes(t))
    })
  }
  if (!searchQuery.value) return list
  const q = searchQuery.value.toLowerCase()
  return list.filter(contact => {
    const name = contactName(contact).toLowerCase()
    const org = fld(contact, 'org').toLowerCase()
    const email = getEmails(contact)
      .map(e => e.value.toLowerCase())
      .join(' ')
    const phone = getPhones(contact)
      .map(p => p.value)
      .join(' ')
    const tags = tagsOf(contact).join(' ')
    return (
      name.includes(q) ||
      org.includes(q) ||
      email.includes(q) ||
      phone.includes(q) ||
      tags.includes(q)
    )
  })
})

const allTags = computed(() => {
  const set = new Set<string>()
  for (const contact of allContacts.value)
    for (const t of tagsOf(contact)) set.add(t)
  return [...set].sort()
})

function toggleTagFilter(tag: string) {
  activeTags.value = activeTags.value.includes(tag)
    ? activeTags.value.filter(t => t !== tag)
    : [...activeTags.value, tag]
}

// A removed tag must release the filter, or the list locks on "No match."
watch(allTags, tags => {
  const kept = activeTags.value.filter(t => tags.includes(t))
  if (kept.length !== activeTags.value.length) activeTags.value = kept
})

// Virtualize the list so a large address book renders only the visible rows.
const {
  list: virtualContacts,
  containerProps,
  wrapperProps
} = useVirtualList(filtered, { itemHeight: 56, overscan: 8 })

const selected = computed(
  () =>
    allContacts.value.find(contact => contact.id === selectedId.value) || null
)

const websiteHref = computed(() =>
  selected.value ? safeUrl(fld(selected.value, 'url')) : null
)

function selectContact(id: string) {
  selectedId.value = id
  mode.value = 'view'
  formError.value = ''
  newTag.value = ''
  newRelId.value = ''
  history.replaceState(null, '', '/apps/contacts?selected=' + id)
  void loadLinked()
}

function onSearch() {
  selectedId.value = null
  mode.value = 'view'
  history.replaceState(null, '', '/apps/contacts')
}

// ----- linked data (events, note mentions) + dashboard-birthday opt-in -----

const linkedEvents = ref<Entry[]>([])
const mentioningNotes = ref<Entry[]>([])
const linkedPhotos = ref<Entry[]>([])
const PHOTO_PREVIEW = 8
// The opt-in list (whose birthdays show in the calendar and on the dashboard)
// lives in its own entry (kind prefs, title birthdays) rather than on the
// contact: vCard connector re-syncs replace contact data wholesale.
const dashPrefs = ref<Entry | null>(null)

async function loadLinked() {
  const id = selectedId.value
  linkedEvents.value = []
  mentioningNotes.value = []
  linkedPhotos.value = []
  if (!id) return
  try {
    const [events, notesRes, prefs, photos] = await Promise.all([
      // q narrows server-side (the id appears in data.contact_id); the
      // filter below makes the match exact.
      props.ctx.api.entries.list({ kind: 'event', q: id }),
      props.ctx.api.fetch(`/api/notes/mentioning/${id}`),
      props.ctx.api.entries.list({ kind: 'prefs' }),
      // Same trick: the id appears in data.faces[].person_id once a face has
      // been named in Photos.
      props.ctx.api.entries.list({ kind: 'photo', q: id })
    ])
    if (id !== selectedId.value) return
    linkedEvents.value = events
      .filter(e => e.data.contact_id === id)
      .sort((a, b) => (b.occurred_at || '').localeCompare(a.occurred_at || ''))
    linkedPhotos.value = photos
      .filter(p => facesOf(p).some(f => f.person_id === id))
      .sort((a, b) =>
        (b.occurred_at || b.inserted_at).localeCompare(
          a.occurred_at || a.inserted_at
        )
      )
    if (notesRes.ok) {
      mentioningNotes.value = (
        (await notesRes.json()) as { data: Entry[] }
      ).data
    }
    dashPrefs.value = prefs.find(p => p.title === 'birthdays') || null
  } catch {
    // linked sections simply stay empty
  }
}

const photoThumb = (p: Entry) => (p.data.thumb_path || p.data.path) as string

// Linked rows are anchors: ctrl/middle-click opens the target in a new tab,
// a plain click stays in the SPA.
function onLinkClick(to: string, e: MouseEvent) {
  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button > 0) return
  e.preventDefault()
  props.ctx.navigate(to)
}

const birthdayOnDashboard = computed(() => {
  const ids = (dashPrefs.value?.data.contact_ids as string[]) || []
  return !!selectedId.value && ids.includes(selectedId.value)
})

async function toggleBirthdayOnDashboard() {
  const id = selectedId.value
  if (!id) return
  const cur = (dashPrefs.value?.data.contact_ids as string[]) || []
  const next = cur.includes(id) ? cur.filter(x => x !== id) : [...cur, id]
  try {
    if (dashPrefs.value) {
      dashPrefs.value = await props.ctx.api.entries.update(dashPrefs.value.id, {
        data: { ...dashPrefs.value.data, contact_ids: next }
      })
    } else {
      dashPrefs.value = await props.ctx.api.entries.create({
        kind: 'prefs',
        source: 'manual',
        title: 'birthdays',
        data: { contact_ids: next }
      })
    }
  } catch {
    // leave the checkbox as-is
  }
}

// ----- "this is me" (singleton prefs entry, like the birthday opt-in) -----

const mePrefs = ref<Entry | null>(null)
const meId = computed(() => (mePrefs.value?.data.contact_id as string) || null)

// ----- relations graph view -----

const graphOpen = ref(false)

function onGraphSelect(id: string) {
  graphOpen.value = false
  selectContact(id)
}

async function toggleMe() {
  const id = selectedId.value
  if (!id) return
  const next = meId.value === id ? null : id
  try {
    if (mePrefs.value) {
      mePrefs.value = await props.ctx.api.entries.update(mePrefs.value.id, {
        data: { ...mePrefs.value.data, contact_id: next }
      })
    } else {
      mePrefs.value = await props.ctx.api.entries.create({
        kind: 'prefs',
        source: 'manual',
        title: 'me',
        data: { contact_id: next }
      })
    }
  } catch {
    // the checkbox reflects the stored state
  }
}

const newTag = ref('')

// All immediate saves (tags, relations) share one serialized chain and
// re-derive from the freshest entry inside it: the backend replaces data
// wholesale, so two in-flight updates on one entry would clobber each other.
let saveChain: Promise<void> = Promise.resolve()

function queueDataSave(
  id: string,
  mutate: (entry: Entry) => Record<string, unknown> | null
) {
  saveChain = saveChain
    .then(async () => {
      const entry = allContacts.value.find(candidate => candidate.id === id)
      if (!entry) return
      const data = mutate(entry)
      if (!data) return
      const updated = await props.ctx.api.entries.update(id, { data })
      allContacts.value = allContacts.value.map(x =>
        x.id === updated.id ? updated : x
      )
    })
    .catch(() => {
      // a failed write re-syncs with the server state on the next load; a
      // failed reciprocal write can leave a one-sided relation, and the x
      // on either card removes both sides
    })
}

function mutateTags(mutate: (cur: string[]) => string[]) {
  const contact = selected.value
  if (!contact) return
  queueDataSave(contact.id, entry => {
    const cur = tagsOf(entry)
    const next = mutate(cur)
    if (next.length === cur.length && next.every((t, i) => t === cur[i])) {
      return null
    }
    return { ...entry.data, tags: next }
  })
}

// Only tags the contact does not already carry; selecting one adds it.
const tagSuggestions = computed(() => {
  if (!selected.value) return []
  const current = tagsOf(selected.value)
  return allTags.value.filter(t => !current.includes(t))
})

function addTag() {
  const tag = newTag.value.trim().toLowerCase()
  newTag.value = ''
  if (!tag) return
  mutateTags(cur => (cur.includes(tag) ? cur : [...cur, tag]))
}

function removeTag(tag: string) {
  mutateTags(cur => cur.filter(t => t !== tag))
}

// ----- renaming a tag everywhere (double-click a chip in the filter bar) -----

const renamingTag = ref<string | null>(null)
const renameTagValue = ref('')
const renameTagInput = ref<HTMLInputElement | null>(null)

async function startRenameTag(tag: string) {
  renamingTag.value = tag
  renameTagValue.value = tag
  await nextTick()
  renameTagInput.value?.select()
}

function commitRenameTag() {
  const from = renamingTag.value
  const to = renameTagValue.value.trim().toLowerCase()
  renamingTag.value = null
  if (!from || !to || to === from) return
  // Every carrier is rewritten through the same serialized chain as a single
  // tag edit, so a rename can't clobber a queued write; a contact that already
  // carries the target tag just ends up with one instead of two.
  for (const contact of allContacts.value) {
    if (!tagsOf(contact).includes(from)) continue
    queueDataSave(contact.id, entry => {
      const cur = tagsOf(entry)
      if (!cur.includes(from)) return null
      return {
        ...entry.data,
        tags: [...new Set(cur.map(tag => (tag === from ? to : tag)))]
      }
    })
  }
  // The filter follows the tag it was pointing at.
  activeTags.value = activeTags.value.map(tag => (tag === from ? to : tag))
}

// ----- relations (reciprocal, saved immediately on both cards) -----

const newRelType = ref<string>('friend')
const newRelId = ref('')

// Free text with suggestions, not a closed list: the six built-in types plus
// whatever custom ones the address book already uses.
const relTypeOptions = computed(() => {
  const used = new Set<string>()
  for (const contact of allContacts.value) {
    for (const relation of relationsOf(contact)) used.add(relation.type)
  }
  for (const type of RELATION_TYPES) used.delete(type)
  return [...RELATION_TYPES, ...[...used].sort()]
})

const relTargets = computed(() =>
  allContacts.value.filter(contact => contact.id !== selectedId.value)
)

// Options carry the contact id, so two contacts sharing a display name
// stay distinct targets.
const relTargetOptions = computed(() =>
  relTargets.value.map(contact => ({
    value: contact.id,
    label: contactName(contact)
  }))
)

const visibleRelations = computed(() => {
  if (!selected.value) return []
  return relationsOf(selected.value)
    .map(relation => ({
      ...relation,
      contact:
        allContacts.value.find(contact => contact.id === relation.contact_id) ||
        null
    }))
    .filter(
      (relation): relation is Relation & { contact: Entry } =>
        relation.contact !== null
    )
})

function queueRelationsSave(
  id: string,
  mutate: (cur: Relation[]) => Relation[]
) {
  queueDataSave(id, entry => ({
    ...entry.data,
    relations: mutate(relationsOf(entry))
  }))
}

function addRelation() {
  const contact = selected.value
  const target = relTargets.value.find(
    candidate => candidate.id === newRelId.value
  )
  const type = normalizeRelationType(newRelType.value)
  if (!contact || !target || !type) return
  newRelId.value = ''
  queueRelationsSave(contact.id, cur => withRelation(cur, target.id, type))
  queueRelationsSave(target.id, cur =>
    withRelation(cur, contact.id, inverseType(type))
  )
}

function removeRelation(contactId: string) {
  const contact = selected.value
  if (!contact) return
  queueRelationsSave(contact.id, cur => withoutRelation(cur, contactId))
  queueRelationsSave(contactId, cur => withoutRelation(cur, contact.id))
}

function openNote(n: Entry) {
  props.ctx.navigate('/apps/notes?selected=' + n.id)
}

// ----- create / edit form -----

function openCreate() {
  form.display_name = ''
  form.org = ''
  form.title = ''
  form.emails = [{ value: '', type: '' }]
  form.phones = [{ value: '', type: '' }]
  form.address = ''
  form.birthday = ''
  form.url = ''
  form.note = ''
  form.photo = ''
  formError.value = ''
  selectedId.value = null
  history.replaceState(null, '', '/apps/contacts')
  mode.value = 'create'
  nextTick(() => nameInput.value?.focus())
}

function openEdit() {
  const contact = selected.value
  if (!contact) return
  form.display_name = fld(contact, 'display_name')
  form.org = fld(contact, 'org')
  form.title = fld(contact, 'title')
  form.emails = getEmails(contact).length
    ? getEmails(contact).map(email => ({ ...email }))
    : [{ value: '', type: '' }]
  form.phones = getPhones(contact).length
    ? getPhones(contact).map(phone => ({ ...phone }))
    : [{ value: '', type: '' }]
  form.address = fld(contact, 'address')
  form.birthday = fld(contact, 'birthday')
  form.url = fld(contact, 'url')
  form.note = fld(contact, 'note')
  form.photo = fld(contact, 'photo')
  formError.value = ''
  mode.value = 'edit'
  nextTick(() => nameInput.value?.focus())
}

function cancelForm() {
  mode.value = 'view'
  formError.value = ''
}

function addEmail() {
  form.emails.push({ value: '', type: '' })
}
function removeEmail(i: number) {
  form.emails.splice(i, 1)
}
function addPhone() {
  form.phones.push({ value: '', type: '' })
}
function removePhone(i: number) {
  form.phones.splice(i, 1)
}

async function uploadPhoto(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  avatarUploading.value = true
  try {
    const res = await props.ctx.api.upload(file, 'contacts')
    form.photo = res.path
  } catch (err) {
    formError.value = err instanceof Error ? err.message : 'Upload failed'
  } finally {
    avatarUploading.value = false
    input.value = ''
  }
}

async function saveForm() {
  const displayName = form.display_name.trim()
  if (!displayName) return
  saving.value = true
  formError.value = ''

  const emails = form.emails
    .filter(email => email.value.trim())
    .map(email => ({ value: email.value.trim(), type: email.type.trim() }))
  const phones = form.phones
    .filter(phone => phone.value.trim())
    .map(phone => ({ value: phone.value.trim(), type: phone.type.trim() }))
  const titleParts = [
    displayName,
    form.org.trim(),
    form.title.trim(),
    emails[0]?.value
  ].filter(Boolean)

  const data = {
    display_name: displayName,
    org: form.org.trim() || null,
    title: form.title.trim() || null,
    emails,
    phones,
    address: form.address.trim() || null,
    birthday: form.birthday.trim() || null,
    url: form.url.trim() || null,
    note: form.note.trim() || null,
    photo: form.photo || null
  }

  try {
    if (mode.value === 'edit' && selected.value) {
      // Drain queued tag/relation saves first: this PATCH replaces data
      // wholesale, and edit mode queues nothing new. The id is captured
      // before the await so a selection switch during the drain cannot
      // redirect the PATCH onto another contact.
      const id = selected.value.id
      await saveChain
      const base = allContacts.value.find(candidate => candidate.id === id)
      const updated = await props.ctx.api.entries.update(id, {
        title: titleParts.join(' - '),
        data: { ...base?.data, ...data }
      })
      allContacts.value = sortContacts(
        allContacts.value.map(contact =>
          contact.id === updated.id ? updated : contact
        )
      )
      selectContact(updated.id)
    } else {
      const created = await props.ctx.api.entries.create({
        kind: 'contact',
        source: 'manual',
        title: titleParts.join(' - '),
        data
      })
      allContacts.value = sortContacts([...allContacts.value, created])
      selectContact(created.id)
    }
  } catch (err) {
    formError.value = err instanceof Error ? err.message : 'Failed to save'
  } finally {
    saving.value = false
  }
}

async function deleteContact() {
  const contact = selected.value
  if (!contact) return
  const ok = await props.ctx.confirm.ask({
    message: `Delete "${contactName(contact)}"?`,
    danger: true
  })
  if (!ok) return
  try {
    await props.ctx.api.entries.delete(contact.id)
    allContacts.value = allContacts.value.filter(
      candidate => candidate.id !== contact.id
    )
    for (const other of allContacts.value) {
      if (
        relationsOf(other).some(relation => relation.contact_id === contact.id)
      ) {
        queueRelationsSave(other.id, cur => withoutRelation(cur, contact.id))
      }
    }
    selectedId.value = null
    history.replaceState(null, '', '/apps/contacts')
  } catch {
    // the contact stays listed; a retry goes through the same button
  }
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape' && mode.value !== 'view') cancelForm()
}

async function reload() {
  loadError.value = ''
  try {
    const entries = await props.ctx.api.entries.list({ kind: 'contact' })
    allContacts.value = sortContacts(entries)
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load contacts'
  } finally {
    loading.value = false
    nextTick(() => searchInput.value?.focus())
  }
  try {
    const prefs = await props.ctx.api.entries.list({ kind: 'prefs' })
    mePrefs.value = prefs.find(entry => entry.title === 'me') || null
  } catch {
    // the ME badge just stays hidden
  }
}

onMounted(() => {
  document.addEventListener('keydown', onKeydown)
  reload()
  if (selectedId.value) void loadLinked()
})
onUnmounted(() => document.removeEventListener('keydown', onKeydown))
</script>

<template>
  <p v-if="loading" class="ct-loading">Scanning address book&hellip;</p>
  <p v-else-if="loadError" class="ct-loading">{{ loadError }}</p>
  <div v-else class="ct-layout">
    <div class="ct-list-col">
      <div class="ct-search-wrap">
        <input
          ref="searchInput"
          v-model="searchQuery"
          class="ct-search"
          type="text"
          placeholder="Search contacts..."
          aria-label="Search contacts"
          @input="onSearch"
        />
      </div>
      <div v-if="allTags.length" class="ct-tag-bar">
        <template v-for="tag in allTags" :key="tag">
          <input
            v-if="renamingTag === tag"
            :ref="el => (renameTagInput = el as HTMLInputElement | null)"
            class="ct-tag-rename"
            v-model="renameTagValue"
            @keyup.enter="commitRenameTag"
            @keyup.esc="renamingTag = null"
            @blur="commitRenameTag"
          />
          <button
            v-else
            class="ct-tag-chip"
            :class="{ 'ct-tag-chip--active': activeTags.includes(tag) }"
            title="Double-click to rename everywhere"
            @click="toggleTagFilter(tag)"
            @dblclick="startRenameTag(tag)"
          >
            {{ tag }}
          </button>
        </template>
        <button
          v-if="activeTags.length > 1"
          class="ct-tag-chip ct-tag-clear"
          @click="activeTags = []"
        >
          Clear
        </button>
      </div>
      <div v-if="filtered.length === 0" class="ct-list">
        <p v-if="allContacts.length === 0" class="ct-empty">
          No contacts yet. Add one, or connect a vCard source.
        </p>
        <p v-else class="ct-empty">No match.</p>
      </div>
      <div v-else class="ct-list" v-bind="containerProps">
        <div v-bind="wrapperProps">
          <div
            v-for="{ data: contact } in virtualContacts"
            :key="contact.id"
            class="ct-card"
            :class="{ 'ct-card--active': contact.id === selectedId }"
            @click="selectContact(contact.id)"
          >
            <span
              v-if="fld(contact, 'photo')"
              class="ct-avatar ct-avatar--photo"
            >
              <img :src="fld(contact, 'photo')" alt="" loading="lazy" />
            </span>
            <span
              v-else
              class="ct-avatar"
              :style="avatarStyle(contactName(contact))"
              >{{ getInitials(contactName(contact)) }}</span
            >
            <div class="ct-card-body">
              <span class="ct-name"
                >{{ contactName(contact)
                }}<span v-if="contact.id === meId" class="ct-me-badge"
                  >ME</span
                ></span
              >
              <span class="ct-sub">{{
                fld(contact, 'org') || getEmails(contact)[0]?.value || ''
              }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="ct-detail-col">
      <div class="ct-detail-topbar">
        <span class="ct-count"
          >{{ filtered.length }}
          <span class="ct-count-unit">{{
            filtered.length === 1 ? 'CONTACT' : 'CONTACTS'
          }}</span></span
        >
        <button
          class="ct-graph-btn"
          :class="{ 'ct-graph-btn--active': graphOpen }"
          title="Relations between contacts (links to you left out)"
          @click="graphOpen = !graphOpen"
        >
          Graph
        </button>
        <button class="ct-add-contact-btn" @click="openCreate">
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <line x1="12" y1="5" x2="12" y2="19" />
            <line x1="5" y1="12" x2="19" y2="12" />
          </svg>
          Add contact
        </button>
      </div>
      <div class="ct-detail-body">
        <RelationsGraph
          v-if="graphOpen"
          :contacts="allContacts"
          :me-id="meId"
          @select="onGraphSelect"
        />
        <!-- Create / edit -->
        <form
          v-else-if="mode !== 'view'"
          class="ct-form"
          @submit.prevent="saveForm"
        >
          <h2 class="ct-form-title">
            {{ mode === 'create' ? 'New contact' : 'Edit contact' }}
          </h2>

          <div class="ct-form-photo">
            <label class="ct-form-avatar">
              <img v-if="form.photo" :src="form.photo" alt="" />
              <span
                v-else
                class="ct-form-avatar-placeholder"
                :style="avatarStyle(form.display_name || '?')"
                >{{ getInitials(form.display_name || '?') }}</span
              >
              <span
                class="ct-form-avatar-overlay"
                :class="{ uploading: avatarUploading }"
              >
                <svg
                  width="20"
                  height="20"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path
                    d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"
                  />
                  <circle cx="12" cy="13" r="3" />
                </svg>
              </span>
              <input
                type="file"
                accept="image/*"
                hidden
                @change="uploadPhoto"
              />
            </label>
          </div>

          <div class="ct-section-card">
            <h3 class="ct-section-title">Basic Info</h3>
            <div class="ct-form-grid">
              <div class="ct-form-field ct-form-field--full">
                <label>Name *</label>
                <input ref="nameInput" v-model="form.display_name" required />
              </div>
              <div class="ct-form-field">
                <label>Organization</label>
                <input v-model="form.org" />
              </div>
              <div class="ct-form-field">
                <label>Title</label>
                <input
                  v-model="form.title"
                  placeholder="e.g. Software Engineer"
                />
              </div>
            </div>
          </div>

          <div class="ct-section-card">
            <h3 class="ct-section-title">Contact</h3>
            <div
              v-for="(email, index) in form.emails"
              :key="'email' + index"
              class="ct-form-row"
            >
              <input
                v-model="email.value"
                type="email"
                placeholder="Email"
                class="ct-form-flex"
              />
              <input
                v-model="email.type"
                placeholder="Type"
                class="ct-form-type"
              />
              <button
                type="button"
                class="ct-row-remove"
                title="Remove"
                @click="removeEmail(index)"
              >
                &times;
              </button>
            </div>
            <button type="button" class="ct-row-add" @click="addEmail">
              + Email
            </button>
            <div
              v-for="(phone, index) in form.phones"
              :key="'phone' + index"
              class="ct-form-row"
            >
              <input
                v-model="phone.value"
                type="tel"
                placeholder="Phone"
                class="ct-form-flex"
              />
              <input
                v-model="phone.type"
                placeholder="Type"
                class="ct-form-type"
              />
              <button
                type="button"
                class="ct-row-remove"
                title="Remove"
                @click="removePhone(index)"
              >
                &times;
              </button>
            </div>
            <button type="button" class="ct-row-add" @click="addPhone">
              + Phone
            </button>
          </div>

          <div class="ct-section-card">
            <h3 class="ct-section-title">Details</h3>
            <div class="ct-form-grid">
              <div class="ct-form-field ct-form-field--full">
                <label>Address</label>
                <input v-model="form.address" />
              </div>
              <div class="ct-form-field">
                <label>Birthday</label>
                <DateInput v-model="form.birthday" />
              </div>
              <div class="ct-form-field">
                <label>Website</label>
                <input
                  v-model="form.url"
                  type="url"
                  placeholder="https://..."
                />
              </div>
            </div>
            <div class="ct-form-field">
              <label>Note</label>
              <textarea v-model="form.note" rows="3"></textarea>
            </div>
          </div>

          <p v-if="formError" class="ct-form-error">{{ formError }}</p>
          <div class="ct-form-actions">
            <button type="button" class="ct-btn" @click="cancelForm">
              Cancel
            </button>
            <button
              type="submit"
              class="ct-btn ct-btn--primary"
              :disabled="saving"
            >
              {{ saving ? 'Saving...' : mode === 'create' ? 'Create' : 'Save' }}
            </button>
          </div>
        </form>

        <!-- View -->
        <div v-else-if="selected" class="ct-detail">
          <div class="ct-detail-header">
            <span
              v-if="fld(selected, 'photo')"
              class="ct-avatar ct-avatar--lg ct-avatar--photo"
            >
              <img :src="fld(selected, 'photo')" alt="" loading="lazy" />
            </span>
            <span
              v-else
              class="ct-avatar ct-avatar--lg"
              :style="avatarStyle(contactName(selected))"
              >{{ getInitials(contactName(selected)) }}</span
            >
            <div>
              <h2 class="ct-detail-name">
                {{ contactName(selected)
                }}<span v-if="meId === selected.id" class="ct-me-badge"
                  >ME</span
                >
              </h2>
              <span
                v-if="fld(selected, 'title') || fld(selected, 'org')"
                class="ct-detail-sub"
                >{{
                  [fld(selected, 'title'), fld(selected, 'org')]
                    .filter(Boolean)
                    .join(' · ')
                }}</span
              >
            </div>
            <button class="ct-footer-btn ct-header-edit" @click="openEdit">
              Edit
            </button>
          </div>

          <div class="ct-header-tags">
            <button
              v-for="tag in tagsOf(selected)"
              :key="tag"
              class="ct-tag-chip"
              @click="toggleTagFilter(tag)"
            >
              {{ tag }}
              <span
                class="ct-tag-x"
                title="Remove tag"
                @click.stop="removeTag(tag)"
                >&times;</span
              >
            </button>
            <AutocompleteInput
              v-model="newTag"
              class="ct-tag-add"
              :options="tagSuggestions"
              placeholder="+ tag"
              @select="addTag"
            />
          </div>

          <div class="ct-section-card">
            <h3 class="ct-section-title">Contact Info</h3>
            <div
              v-for="(email, index) in getEmails(selected)"
              :key="'email' + index"
              class="ct-info-row"
            >
              <svg
                class="ct-info-icon"
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <rect width="20" height="16" x="2" y="4" rx="2" />
                <path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7" />
              </svg>
              <div class="ct-info-body">
                <a class="ct-link" :href="'mailto:' + email.value">{{
                  email.value
                }}</a>
                <span v-if="email.type" class="ct-info-type">{{
                  email.type
                }}</span>
              </div>
            </div>
            <div
              v-for="(phone, index) in getPhones(selected)"
              :key="'phone' + index"
              class="ct-info-row"
            >
              <svg
                class="ct-info-icon"
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path
                  d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"
                />
              </svg>
              <div class="ct-info-body">
                <a class="ct-link" :href="'tel:' + phone.value">{{
                  phone.value
                }}</a>
                <span v-if="phone.type" class="ct-info-type">{{
                  phone.type
                }}</span>
              </div>
            </div>
            <span
              v-if="!getEmails(selected).length && !getPhones(selected).length"
              class="ct-muted"
            >
              No contact info
            </span>
          </div>

          <div
            v-if="
              fld(selected, 'address') ||
              fld(selected, 'birthday') ||
              fld(selected, 'url') ||
              fld(selected, 'note')
            "
            class="ct-section-card"
          >
            <h3 class="ct-section-title">Details</h3>
            <div class="ct-meta-list">
              <div v-if="fld(selected, 'address')" class="ct-meta-row">
                <span class="ct-meta-key">Address</span
                ><span>{{ fld(selected, 'address') }}</span>
              </div>
              <div v-if="fld(selected, 'birthday')" class="ct-meta-row">
                <span class="ct-meta-key">Birthday</span
                ><span>{{ fld(selected, 'birthday') }}</span>
              </div>
              <div v-if="fld(selected, 'url')" class="ct-meta-row">
                <span class="ct-meta-key">Website</span>
                <span>
                  <a
                    v-if="websiteHref"
                    class="ct-link"
                    :href="websiteHref"
                    target="_blank"
                    rel="noopener"
                    >{{ fld(selected, 'url') }}</a
                  >
                  <template v-else>{{ fld(selected, 'url') }}</template>
                </span>
              </div>
              <div v-if="fld(selected, 'note')" class="ct-meta-row">
                <span class="ct-meta-key">Note</span>
                <span class="ct-note">{{ fld(selected, 'note') }}</span>
              </div>
            </div>
          </div>

          <!-- The whole address book relates to me: that list says nothing. -->
          <div v-if="selected.id !== meId" class="ct-section-card">
            <h3 class="ct-section-title">Relations</h3>
            <div
              v-for="relation in visibleRelations"
              :key="relation.contact_id"
              class="ct-linked-row"
              role="button"
              tabindex="0"
              @click="selectContact(relation.contact_id)"
              @keydown.enter="selectContact(relation.contact_id)"
            >
              <span class="ct-linked-meta">{{
                relationLabel(relation.type)
              }}</span>
              <span class="ct-linked-title">{{
                contactName(relation.contact)
              }}</span>
              <span
                class="ct-rel-x"
                title="Remove relation"
                @click.stop="removeRelation(relation.contact_id)"
                >&times;</span
              >
            </div>
            <form class="ct-rel-add" @submit.prevent="addRelation">
              <AutocompleteInput
                v-model="newRelType"
                class="ct-rel-type"
                :options="relTypeOptions"
                placeholder="Relation..."
              />
              <ComboBox
                v-model="newRelId"
                class="ct-rel-name"
                :options="relTargetOptions"
                placeholder="Contact..."
              />
              <button type="submit" class="ct-rel-btn" :disabled="!newRelId">
                Link
              </button>
            </form>
          </div>

          <div class="ct-section-card">
            <h3 class="ct-section-title">Parameters</h3>
            <div class="ct-param-list">
              <!-- Once a me contact exists, only it shows the toggle (to unset). -->
              <label
                v-if="!meId || meId === selected.id"
                class="ct-dash-toggle"
              >
                <input
                  type="checkbox"
                  :checked="meId === selected.id"
                  @change="toggleMe"
                />
                <User :size="14" /> This is me
              </label>
              <label v-if="fld(selected, 'birthday')" class="ct-dash-toggle">
                <input
                  type="checkbox"
                  :checked="birthdayOnDashboard"
                  @change="toggleBirthdayOnDashboard"
                />
                <Cake :size="14" /> Show this birthday in the calendar and on
                the dashboard
              </label>
            </div>
          </div>

          <div v-if="linkedEvents.length" class="ct-section-card">
            <h3 class="ct-section-title">Events</h3>
            <div
              v-for="event in linkedEvents.slice(0, 8)"
              :key="event.id"
              class="ct-linked-row"
              role="button"
              tabindex="0"
              @click="ctx.navigate('/apps/calendar')"
              @keydown.enter="ctx.navigate('/apps/calendar')"
            >
              <span class="ct-linked-meta">{{
                formatDate(event.occurred_at || event.inserted_at)
              }}</span>
              <span class="ct-linked-title">
                <span v-if="event.data.recurrence" title="Recurring">↻</span>
                {{ event.title || 'Untitled' }}
              </span>
            </div>
          </div>

          <div v-if="linkedPhotos.length" class="ct-section-card">
            <h3 class="ct-section-title">Photos</h3>
            <div class="ct-photo-grid">
              <a
                v-for="photo in linkedPhotos.slice(0, PHOTO_PREVIEW)"
                :key="photo.id"
                class="ct-photo"
                :href="`/photos/${photo.id}`"
                @click="onLinkClick(`/photos/${photo.id}`, $event)"
              >
                <img
                  :src="photoThumb(photo)"
                  :alt="photo.title || 'Photo'"
                  loading="lazy"
                />
              </a>
            </div>
            <a
              class="ct-photo-all"
              :href="`/apps/photos?person=${selectedId}`"
              @click="onLinkClick(`/apps/photos?person=${selectedId}`, $event)"
            >
              {{
                linkedPhotos.length > PHOTO_PREVIEW
                  ? `See all ${linkedPhotos.length} photos`
                  : 'Open in Photos'
              }}
            </a>
          </div>

          <div v-if="mentioningNotes.length" class="ct-section-card">
            <h3 class="ct-section-title">Mentioned in</h3>
            <div
              v-for="note in mentioningNotes"
              :key="note.id"
              class="ct-linked-row"
              role="button"
              tabindex="0"
              @click="openNote(note)"
              @keydown.enter="openNote(note)"
            >
              <span class="ct-linked-title">{{
                note.title || 'Untitled'
              }}</span>
              <span v-if="note.data.folder" class="ct-linked-meta">{{
                note.data.folder
              }}</span>
            </div>
          </div>

          <div class="ct-section-card ct-section-card--muted">
            <h3 class="ct-section-title">Info</h3>
            <div class="ct-meta-list">
              <div class="ct-meta-row">
                <span class="ct-meta-key">Source</span>
                <span>{{
                  fld(selected, 'source_name') || selected.source
                }}</span>
              </div>
              <div class="ct-meta-row">
                <span class="ct-meta-key">Added</span>
                <span>{{ formatDate(selected.inserted_at) }}</span>
              </div>
              <div v-if="selected.external_id" class="ct-meta-row">
                <span class="ct-meta-key">ID</span>
                <span class="ct-mono">{{ selected.external_id }}</span>
              </div>
            </div>
          </div>

          <div class="ct-detail-footer">
            <button
              class="ct-footer-btn ct-footer-btn--danger"
              @click="deleteContact"
            >
              Delete contact
            </button>
          </div>
        </div>
        <p v-else class="ct-placeholder">Select a contact to view details</p>
      </div>
    </div>
  </div>
</template>

<style scoped>
.ct-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: var(--font-mono);
}
.ct-layout {
  display: flex;
  height: 100vh;
}
.ct-list-col {
  width: 360px;
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
}
.ct-detail-col {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.ct-detail-topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1.5rem;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.ct-detail-body {
  flex: 1;
  overflow-y: auto;
  padding: 1.5rem;
}
.ct-search-wrap {
  padding: 0.75rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  border-bottom: 1px solid var(--border);
}
.ct-search {
  flex: 1;
}
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
.ct-tag-clear {
  color: var(--text-muted);
  border-style: dashed;
}
.ct-tag-rename {
  width: 7rem;
  padding: 0.15rem 0.5rem;
  border: 1px solid var(--primary);
  border-radius: 999px;
  background: var(--bg-surface);
  color: var(--text);
  font-size: 0.78rem;
}
.ct-count {
  font-family: var(--font-mono);
  font-size: 0.85rem;
  color: var(--text);
  white-space: nowrap;
}
.ct-count-unit {
  color: var(--text-muted);
  letter-spacing: 0.08em;
}
.ct-list {
  flex: 1;
  overflow-y: auto;
  padding: 0.375rem;
}
.ct-card {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.6rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
  transition: background 0.1s;
}
.ct-card:hover {
  background: var(--bg-hover);
}
/* Cursor row: violet rail + tint, like a terminal selection */
.ct-card--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 8px 8px 0;
}
.ct-avatar {
  width: 36px;
  height: 36px;
  border-radius: 50%;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 0.8rem;
  font-weight: 600;
  flex-shrink: 0;
}
.ct-avatar--lg {
  width: 56px;
  height: 56px;
  font-size: 1.2rem;
}
.ct-card-body {
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.ct-name {
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.ct-sub {
  font-size: 0.85rem;
  color: var(--text-muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.ct-empty,
.ct-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem 1rem;
  font-family: var(--font-mono);
  font-size: 0.88rem;
}
.ct-detail {
  max-width: 640px;
}
.ct-detail-header {
  display: flex;
  align-items: center;
  gap: 1rem;
  margin-bottom: 0.75rem;
}
.ct-detail-name {
  margin: 0;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.6rem;
  letter-spacing: 0.03em;
}
.ct-detail-sub {
  font-size: 0.9rem;
  color: var(--text-muted);
}
.ct-header-tags {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.375rem;
  margin-bottom: 1.25rem;
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
.ct-tag-add {
  width: 90px;
}
.ct-tag-add :deep(input) {
  width: 100%;
  padding: 0.15rem 0.5rem;
  font-size: 0.78rem;
  border-radius: 999px;
  background: transparent;
  border: 1px dashed var(--border);
}
.ct-tag-add :deep(input:focus) {
  border-style: solid;
}
/* The wrapper is chip-sized; let the suggestion list breathe past it. */
.ct-tag-add :deep(.ac-list) {
  min-width: 160px;
  right: auto;
}
.ct-header-edit {
  margin-left: auto;
  align-self: flex-start;
}
.ct-avatar--photo {
  padding: 0;
  background: none;
}
.ct-avatar--photo img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
  border-radius: 50%;
}
.ct-section-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem;
  margin-bottom: 0.75rem;
}
.ct-section-card--muted {
  background: transparent;
  border-color: var(--border);
  opacity: 0.7;
}
.ct-section-title {
  margin: 0 0 0.6rem;
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
}
.ct-info-row {
  display: flex;
  align-items: flex-start;
  gap: 0.6rem;
  padding: 0.45rem 0;
  border-bottom: 1px solid var(--border);
}
.ct-info-row:last-of-type {
  border-bottom: none;
}
.ct-info-icon {
  color: var(--text-muted);
  margin-top: 0.15rem;
  flex-shrink: 0;
}
.ct-info-body {
  display: flex;
  flex-direction: column;
}
.ct-info-type {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: capitalize;
}
.ct-meta-list {
  display: flex;
  flex-direction: column;
}
.ct-meta-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1rem;
  padding: 0.4rem 0;
  border-bottom: 1px solid var(--border);
  font-size: 0.9rem;
}
.ct-meta-row:last-child {
  border-bottom: none;
}
.ct-meta-key {
  color: var(--text-muted);
  flex-shrink: 0;
}
.ct-link {
  color: var(--primary);
  text-decoration: none;
  word-break: break-all;
}
.ct-link:hover {
  text-decoration: underline;
}
.ct-muted {
  color: var(--text-muted);
  font-size: 0.9rem;
}
.ct-note {
  white-space: pre-wrap;
  font-size: 0.9rem;
  color: var(--text-muted);
}
.ct-mono {
  font-family: var(--font-mono);
  font-size: 0.85rem;
}
.ct-photo-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(72px, 1fr));
  gap: 0.4rem;
}
.ct-photo {
  display: block;
  aspect-ratio: 1;
  border-radius: 6px;
  overflow: hidden;
  background: var(--bg-hover);
}
.ct-photo img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.ct-photo:hover {
  outline: 2px solid var(--primary);
}
.ct-photo-all {
  display: inline-block;
  margin-top: 0.55rem;
  color: var(--primary);
  font-size: 0.85rem;
  text-decoration: none;
  cursor: pointer;
}
.ct-photo-all:hover {
  text-decoration: underline;
}
.ct-linked-row {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  padding: 0.45rem 0.25rem;
  border-bottom: 1px solid var(--border);
  font-size: 0.9rem;
  cursor: pointer;
  border-radius: 6px;
}
.ct-linked-row:last-child {
  border-bottom: none;
}
.ct-linked-row:hover {
  background: var(--bg-hover);
}
.ct-linked-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.ct-linked-meta {
  color: var(--text-muted);
  font-size: 0.8rem;
  flex-shrink: 0;
}
.ct-linked-row .ct-linked-meta:last-child {
  margin-left: auto;
}
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
.ct-me-badge {
  margin-left: 0.4rem;
  font-family: var(--font-mono);
  font-size: 0.62rem;
  letter-spacing: 0.08em;
  padding: 0.05rem 0.4rem;
  border-radius: 999px;
  border: 1px solid var(--primary);
  color: var(--primary);
  vertical-align: middle;
}
.ct-param-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.ct-dash-toggle {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  cursor: pointer;
  color: var(--text);
}
.ct-dash-toggle input {
  width: 15px;
  height: 15px;
  padding: 0;
  margin: 0;
  accent-color: var(--primary);
}
.ct-detail-footer {
  margin-top: 0.5rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
  display: flex;
  justify-content: flex-end;
}
.ct-footer-btn {
  font-size: 0.85rem;
  color: var(--text-muted);
  background: transparent;
  border: 1px solid var(--border);
  padding: 0.4rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
}
.ct-footer-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.ct-footer-btn--danger:hover {
  color: var(--danger);
  border-color: var(--danger);
  background: rgba(240, 108, 108, 0.08);
}
.ct-graph-btn {
  /* The topbar is space-between: push the button into the right group. */
  margin-left: auto;
  margin-right: 0.5rem;
  height: 32px;
  padding: 0 0.75rem;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  font-size: 0.85rem;
  cursor: pointer;
}
.ct-graph-btn:hover,
.ct-graph-btn--active {
  border-color: var(--primary);
  color: var(--primary);
}
.ct-add-contact-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  height: 32px;
  padding: 0 0.75rem;
  border-radius: 8px;
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  font-size: 0.85rem;
  cursor: pointer;
  flex-shrink: 0;
}
.ct-add-contact-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}

/* Create / edit form */
.ct-form {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  max-width: 640px;
}
.ct-form-title {
  margin: 0;
  font-family: var(--font-display);
  font-weight: 400;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  font-size: 1.4rem;
}
.ct-form-photo {
  display: flex;
  justify-content: center;
}
.ct-form-avatar {
  position: relative;
  width: 72px;
  height: 72px;
  border-radius: 50%;
  cursor: pointer;
  overflow: hidden;
}
.ct-form-avatar img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.ct-form-avatar-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  font-size: 1.4rem;
  font-weight: 600;
}
.ct-form-avatar-overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.5);
  color: #fff;
  opacity: 0;
  transition: opacity 0.15s;
}
.ct-form-avatar-overlay.uploading {
  opacity: 0.6;
}
.ct-form-avatar:hover .ct-form-avatar-overlay {
  opacity: 1;
}
.ct-form-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0.75rem;
  margin-bottom: 0.5rem;
}
.ct-form-field--full {
  grid-column: 1 / -1;
}
.ct-form-field {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.ct-form-field label {
  font-size: 0.8rem;
  color: var(--text-muted);
}
.ct-form-row {
  display: flex;
  gap: 0.375rem;
  margin-bottom: 0.375rem;
}
.ct-form-flex {
  flex: 1;
}
.ct-form-type {
  width: 90px;
}
.ct-row-remove {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 8px;
  cursor: pointer;
  padding: 0;
  flex-shrink: 0;
}
.ct-row-remove:hover {
  color: var(--danger);
  border-color: var(--danger);
}
.ct-row-add {
  align-self: flex-start;
  background: transparent;
  border: none;
  color: var(--primary);
  font-size: 0.85rem;
  cursor: pointer;
  padding: 0.3rem 0;
}
.ct-row-add:hover {
  text-decoration: underline;
}
.ct-form-error {
  color: var(--danger);
  font-size: 0.85rem;
  margin: 0;
}
.ct-form-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}
.ct-btn {
  padding: 0.5rem 1rem;
  border-radius: 8px;
  font-size: 0.9rem;
  font-weight: 500;
  cursor: pointer;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}
.ct-btn:hover {
  border-color: var(--text-muted);
}
.ct-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.ct-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}
.ct-btn--primary:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
</style>
