<script setup lang="ts">
import { ref, reactive, computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useApi } from '../composables/useApi'
import { useFetchData } from '../composables/useFetchData'
import { useAuthStore } from '../stores/auth'
import { useConfirm } from '../composables/useConfirm'
import {
  ArrowLeft,
  Trash2,
  Mail,
  Phone,
  Pencil,
  Camera,
  X as XIcon,
  Plus
} from 'lucide-vue-next'
import type { Entry } from '../types'
import { safeUrl } from '../lib/url'
import { formatDate } from '../lib/datetime'
import { contactField, contactName, contactInitials } from '../lib/contact'

const route = useRoute()
const router = useRouter()
const api = useApi()
const auth = useAuthStore()
const { ask } = useConfirm()

const {
  data: entry,
  loading,
  error,
  refetch
} = useFetchData<Entry>(
  () =>
    api
      .get<{ data: Entry }>(`/api/entries/${route.params.id}`)
      .then(r => r.data),
  {
    fallbackError: 'Contact not found',
    onSuccess: () => {
      if (route.query.edit) startEdit()
      void loadLinked()
    }
  }
)

// The component instance is reused across /contacts/:id navigations (no router
// key), and useFetchData only fetches on mount, so refetch when the id changes.
watch(
  () => route.params.id,
  () => {
    refetch()
    void loadLinked()
  }
)

// ----- linked data (events, note mentions) + dashboard-birthday opt-in -----

const linkedEvents = ref<Entry[]>([])
const mentioningNotes = ref<Entry[]>([])
// The opt-in list (whose birthdays show in the calendar and on the dashboard)
// lives in its own entry (kind prefs, title birthdays) rather than on the
// contact: vCard connector re-syncs replace contact data wholesale.
const dashPrefs = ref<Entry | null>(null)

async function loadLinked() {
  const id = route.params.id as string
  try {
    const [events, notes, prefs] = await Promise.all([
      // q narrows server-side (the id appears in data.contact_id); the
      // filter below makes the match exact.
      api.get<{ data: Entry[] }>('/api/entries', {
        kind: 'event',
        q: id,
        per_page: '200'
      }),
      api.get<{ data: Entry[] }>(`/api/notes/mentioning/${id}`),
      api.get<{ data: Entry[] }>('/api/entries', {
        kind: 'prefs',
        per_page: '10'
      })
    ])
    linkedEvents.value = events.data
      .filter(e => e.data.contact_id === id)
      .sort((a, b) => (b.occurred_at || '').localeCompare(a.occurred_at || ''))
    mentioningNotes.value = notes.data
    dashPrefs.value = prefs.data.find(p => p.title === 'birthdays') || null
  } catch {
    // linked sections simply stay empty
  }
}

const birthdayOnDashboard = computed(() => {
  const ids = (dashPrefs.value?.data.contact_ids as string[]) || []
  return ids.includes(route.params.id as string)
})

async function toggleBirthdayOnDashboard() {
  const id = route.params.id as string
  const cur = (dashPrefs.value?.data.contact_ids as string[]) || []
  const next = cur.includes(id) ? cur.filter(x => x !== id) : [...cur, id]
  try {
    if (dashPrefs.value) {
      const res = await api.put<{ data: Entry }>(
        `/api/entries/${dashPrefs.value.id}`,
        { data: { ...dashPrefs.value.data, contact_ids: next } }
      )
      dashPrefs.value = res.data
    } else {
      const res = await api.post<{ data: Entry }>('/api/entries', {
        kind: 'prefs',
        source: 'manual',
        title: 'birthdays',
        data: { contact_ids: next }
      })
      dashPrefs.value = res.data
    }
  } catch {
    // leave the checkbox as-is
  }
}

function openNote(n: Entry) {
  router.push({ path: '/apps/notes', query: { selected: n.id } })
}
const editing = ref(false)
const saving = ref(false)
const avatarUploading = ref(false)

// Edit form
const form = reactive({
  display_name: '',
  org: '',
  title: '',
  emails: [] as { value: string; type: string }[],
  phones: [] as { value: string; type: string }[],
  address: '',
  birthday: '',
  url: '',
  note: '',
  photo: ''
})

function f(key: string): string {
  return entry.value ? contactField(entry.value, key) : ''
}

const name = computed(() =>
  entry.value ? contactName(entry.value) : '(unnamed)'
)
const initials = computed(() => contactInitials(name.value))
const emails = computed(
  () => (entry.value?.data?.emails as { value: string; type: string }[]) || []
)
const phones = computed(
  () => (entry.value?.data?.phones as { value: string; type: string }[]) || []
)
const photo = computed(() => f('photo'))

function startEdit() {
  if (!entry.value) return
  form.display_name = f('display_name')
  form.org = f('org')
  form.title = f('title')
  form.emails = emails.value.length
    ? emails.value.map(e => ({ ...e }))
    : [{ value: '', type: '' }]
  form.phones = phones.value.length
    ? phones.value.map(p => ({ ...p }))
    : [{ value: '', type: '' }]
  form.address = f('address')
  form.birthday = f('birthday')
  form.url = f('url')
  form.note = f('note')
  form.photo = f('photo')
  editing.value = true
}

function cancelEdit() {
  editing.value = false
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
    const fd = new FormData()
    fd.append('file', file)
    fd.append('app', 'contacts')
    const res = await fetch('/api/uploads', {
      method: 'POST',
      headers: auth.token ? { Authorization: `Bearer ${auth.token}` } : {},
      body: fd
    })
    const data = await res.json()
    if (res.ok) form.photo = data.path
  } finally {
    avatarUploading.value = false
    input.value = ''
  }
}

async function saveEdit() {
  if (!entry.value) return
  saving.value = true
  try {
    const cleanEmails = form.emails.filter(e => e.value.trim())
    const cleanPhones = form.phones.filter(p => p.value.trim())
    const titleParts = [
      form.display_name,
      form.org,
      form.title,
      cleanEmails[0]?.value
    ].filter(Boolean)

    const data = {
      ...entry.value.data,
      display_name: form.display_name,
      org: form.org || null,
      title: form.title || null,
      emails: cleanEmails,
      phones: cleanPhones,
      address: form.address || null,
      birthday: form.birthday || null,
      url: form.url || null,
      note: form.note || null,
      photo: form.photo || null
    }

    const res = await api.put<{ data: Entry }>(
      `/api/entries/${entry.value.id}`,
      {
        title: titleParts.join(' - '),
        data
      }
    )
    entry.value = res.data
    editing.value = false
  } catch (e: any) {
    error.value = e.message || 'Failed to save'
  } finally {
    saving.value = false
  }
}

async function deleteContact() {
  if (!entry.value) return
  const ok = await ask({ message: `Delete "${name.value}"?` })
  if (!ok) return
  await api.del(`/api/entries/${entry.value.id}`)
  router.push('/apps/contacts')
}
</script>

<template>
  <div class="view contact-detail">
    <div class="ct-topbar">
      <router-link to="/apps/contacts" class="back-link">
        <ArrowLeft :size="20" />
      </router-link>
      <h1 v-if="entry">{{ name }}</h1>
      <h1 v-else-if="loading">Loading...</h1>
      <button v-if="entry && !editing" class="ct-edit-btn" @click="startEdit">
        <Pencil :size="15" /> Edit
      </button>
    </div>

    <p v-if="error" class="ct-error">{{ error }}</p>

    <!-- Edit mode -->
    <template v-if="entry && editing">
      <form class="ct-edit-form" @submit.prevent="saveEdit">
        <!-- Photo -->
        <div class="ct-edit-photo-section">
          <label class="ct-edit-avatar-wrap">
            <img
              v-if="form.photo"
              :src="form.photo"
              class="ct-edit-avatar-img"
            />
            <span v-else class="ct-edit-avatar-placeholder">{{
              initials
            }}</span>
            <span
              class="ct-edit-avatar-overlay"
              :class="{ uploading: avatarUploading }"
            >
              <Camera :size="20" />
            </span>
            <input type="file" accept="image/*" hidden @change="uploadPhoto" />
          </label>
        </div>

        <div class="ct-edit-grid">
          <!-- Basic info -->
          <section class="ct-card">
            <h3>Basic Info</h3>
            <div class="ct-fields-row">
              <div class="field">
                <label>Name</label>
                <input v-model="form.display_name" required />
              </div>
              <div class="field">
                <label>Organization</label>
                <input v-model="form.org" />
              </div>
              <div class="field">
                <label>Title</label>
                <input
                  v-model="form.title"
                  placeholder="e.g. Software Engineer"
                />
              </div>
            </div>
          </section>

          <!-- Contact -->
          <section class="ct-card">
            <h3>Contact</h3>
            <div
              v-for="(e, i) in form.emails"
              :key="'e' + i"
              class="ct-multi-row"
            >
              <input
                v-model="e.value"
                type="email"
                placeholder="Email"
                class="ct-multi-input"
              />
              <input
                v-model="e.type"
                placeholder="Type"
                class="ct-multi-type"
              />
              <button
                type="button"
                class="ct-multi-remove"
                @click="removeEmail(i)"
              >
                <XIcon :size="14" />
              </button>
            </div>
            <button type="button" class="ct-add-btn" @click="addEmail">
              <Plus :size="14" /> Email
            </button>

            <div
              v-for="(p, i) in form.phones"
              :key="'p' + i"
              class="ct-multi-row"
            >
              <input
                v-model="p.value"
                type="tel"
                placeholder="Phone"
                class="ct-multi-input"
              />
              <input
                v-model="p.type"
                placeholder="Type"
                class="ct-multi-type"
              />
              <button
                type="button"
                class="ct-multi-remove"
                @click="removePhone(i)"
              >
                <XIcon :size="14" />
              </button>
            </div>
            <button type="button" class="ct-add-btn" @click="addPhone">
              <Plus :size="14" /> Phone
            </button>
          </section>

          <!-- Details -->
          <section class="ct-card">
            <h3>Details</h3>
            <div class="ct-fields-row">
              <div class="field">
                <label>Address</label>
                <input v-model="form.address" />
              </div>
              <div class="field">
                <label>Birthday</label>
                <input v-model="form.birthday" type="date" />
              </div>
              <div class="field">
                <label>Website</label>
                <input
                  v-model="form.url"
                  type="url"
                  placeholder="https://..."
                />
              </div>
            </div>
            <div class="field">
              <label>Note</label>
              <textarea v-model="form.note" rows="3"></textarea>
            </div>
          </section>
        </div>

        <div class="ct-edit-actions">
          <button type="button" class="ct-btn-cancel" @click="cancelEdit">
            Cancel
          </button>
          <button type="submit" :disabled="saving">
            {{ saving ? 'Saving...' : 'Save' }}
          </button>
        </div>
      </form>
    </template>

    <!-- View mode -->
    <template v-else-if="entry && !loading">
      <div class="ct-page-layout">
        <div class="ct-header-card">
          <label v-if="photo" class="ct-avatar ct-avatar--photo">
            <img :src="photo" alt="" />
          </label>
          <span v-else class="ct-avatar">{{ initials }}</span>
          <div class="ct-header-info">
            <h2>{{ name }}</h2>
            <span v-if="f('title') || f('org')" class="ct-header-sub">
              {{ [f('title'), f('org')].filter(Boolean).join(' · ') }}
            </span>
          </div>
        </div>

        <div class="ct-page-grid">
          <section class="ct-card">
            <h3>Contact Info</h3>
            <div v-for="e in emails" :key="e.value" class="ct-info-row">
              <Mail :size="16" class="ct-info-icon" />
              <div class="ct-info-body">
                <a :href="`mailto:${e.value}`" class="ct-link">{{ e.value }}</a>
                <span v-if="e.type" class="ct-info-type">{{ e.type }}</span>
              </div>
            </div>
            <div v-for="p in phones" :key="p.value" class="ct-info-row">
              <Phone :size="16" class="ct-info-icon" />
              <div class="ct-info-body">
                <a :href="`tel:${p.value}`" class="ct-link">{{ p.value }}</a>
                <span v-if="p.type" class="ct-info-type">{{ p.type }}</span>
              </div>
            </div>
            <p v-if="!emails.length && !phones.length" class="ct-muted">
              No contact info
            </p>
          </section>

          <section
            v-if="f('address') || f('birthday') || f('url') || f('note')"
            class="ct-card"
          >
            <h3>Details</h3>
            <div class="ct-meta-list">
              <div v-if="f('address')" class="ct-meta-row">
                <span class="ct-meta-key">Address</span>
                <span>{{ f('address') }}</span>
              </div>
              <div v-if="f('birthday')" class="ct-meta-row">
                <span class="ct-meta-key">Birthday</span>
                <span>{{ f('birthday') }}</span>
              </div>
              <div v-if="f('birthday')" class="ct-meta-row">
                <span class="ct-meta-key">Reminder</span>
                <label
                  class="ct-dash-toggle"
                  title="Show this birthday in the calendar and on the dashboard"
                >
                  <input
                    type="checkbox"
                    :checked="birthdayOnDashboard"
                    @change="toggleBirthdayOnDashboard"
                  />
                  🎂 calendar + dashboard
                </label>
              </div>
              <div v-if="f('url')" class="ct-meta-row">
                <span class="ct-meta-key">Website</span>
                <a
                  v-if="safeUrl(f('url'))"
                  :href="safeUrl(f('url'))!"
                  target="_blank"
                  rel="noopener"
                  class="ct-link"
                  >{{ f('url') }}</a
                >
                <span v-else class="ct-link">{{ f('url') }}</span>
              </div>
              <div v-if="f('note')" class="ct-meta-row">
                <span class="ct-meta-key">Note</span>
                <span class="ct-note-text">{{ f('note') }}</span>
              </div>
            </div>
          </section>

          <section v-if="linkedEvents.length" class="ct-card">
            <h3>Events</h3>
            <div
              v-for="e in linkedEvents.slice(0, 8)"
              :key="e.id"
              class="ct-linked-row"
              role="button"
              tabindex="0"
              @click="router.push('/apps/calendar')"
            >
              <span class="ct-linked-meta">{{
                formatDate(e.occurred_at || e.inserted_at)
              }}</span>
              <span class="ct-linked-title">
                <span v-if="e.data.recurrence" title="Recurring">↻</span>
                {{ e.title || 'Untitled' }}
              </span>
            </div>
          </section>

          <section v-if="mentioningNotes.length" class="ct-card">
            <h3>Mentioned in</h3>
            <div
              v-for="n in mentioningNotes"
              :key="n.id"
              class="ct-linked-row"
              role="button"
              tabindex="0"
              @click="openNote(n)"
            >
              <span class="ct-linked-title">{{ n.title || 'Untitled' }}</span>
              <span v-if="n.data.folder" class="ct-linked-meta">{{
                n.data.folder
              }}</span>
            </div>
          </section>

          <section class="ct-card ct-card--muted">
            <h3>Info</h3>
            <div class="ct-meta-list">
              <div class="ct-meta-row">
                <span class="ct-meta-key">Source</span>
                <span>{{ f('source_name') || entry.source }}</span>
              </div>
              <div class="ct-meta-row">
                <span class="ct-meta-key">Added</span>
                <span>{{ formatDate(entry.inserted_at) }}</span>
              </div>
              <div v-if="entry.external_id" class="ct-meta-row">
                <span class="ct-meta-key">External ID</span>
                <span class="ct-mono">{{ entry.external_id }}</span>
              </div>
            </div>
          </section>
        </div>

        <div class="ct-page-actions">
          <span class="ct-permalink"
            >Permalink: <code>/contacts/{{ entry.id }}</code></span
          >
          <button class="ct-delete-btn" @click="deleteContact">
            <Trash2 :size="15" /> Delete contact
          </button>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.contact-detail {
  max-width: 900px;
}

.ct-topbar {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1.25rem;
}
.ct-topbar h1 {
  margin: 0;
  font-size: 1.25rem;
  flex: 1;
}

.back-link {
  color: var(--text-muted);
  display: flex;
}
.back-link:hover {
  color: var(--text);
}

.ct-edit-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.4rem 0.85rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
}
.ct-edit-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}

.ct-error {
  color: var(--danger);
}

/* Header card */
.ct-header-card {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 1.25rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  margin-bottom: 1rem;
}

.ct-avatar {
  width: 64px;
  height: 64px;
  border-radius: 50%;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1.3rem;
  font-weight: 600;
  flex-shrink: 0;
  overflow: hidden;
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
}

.ct-header-info h2 {
  margin: 0;
  font-size: 1.25rem;
}
.ct-header-sub {
  font-size: 0.9rem;
  color: var(--text-muted);
}

/* Grid */
.ct-page-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
  margin-bottom: 1rem;
}

.ct-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.25rem;
}
.ct-card--muted {
  background: transparent;
  opacity: 0.7;
}
.ct-card h3 {
  margin: 0 0 0.75rem;
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
}

.ct-info-row {
  display: flex;
  align-items: flex-start;
  gap: 0.6rem;
  padding: 0.5rem 0;
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

.ct-meta-list {
  display: flex;
  flex-direction: column;
}
.ct-meta-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 1rem;
  padding: 0.45rem 0;
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
.ct-note-text {
  white-space: pre-wrap;
  color: var(--text-muted);
  text-align: right;
}
.ct-mono {
  font-family: monospace;
  font-size: 0.85rem;
  word-break: break-all;
}

/* Linked events / mentioning notes */
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

.ct-page-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.ct-permalink {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.ct-permalink code {
  color: var(--primary);
}

.ct-delete-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.45rem 0.85rem;
  border-radius: 8px;
  font-size: 0.875rem;
  cursor: pointer;
}
.ct-delete-btn:hover {
  color: var(--danger);
  border-color: var(--danger);
  background: rgba(240, 108, 108, 0.08);
}

/* Edit form */
.ct-edit-form {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.ct-edit-photo-section {
  display: flex;
  justify-content: center;
  margin-bottom: 0.5rem;
}

.ct-edit-avatar-wrap {
  position: relative;
  width: 80px;
  height: 80px;
  border-radius: 50%;
  cursor: pointer;
  overflow: hidden;
}
.ct-edit-avatar-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.ct-edit-avatar-placeholder {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  font-size: 1.5rem;
  font-weight: 600;
}
.ct-edit-avatar-overlay {
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
.ct-edit-avatar-overlay.uploading {
  opacity: 0.6;
}
.ct-edit-avatar-wrap:hover .ct-edit-avatar-overlay {
  opacity: 1;
}

.ct-edit-grid {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.ct-fields-row {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0.75rem;
}

/* Multi-value rows (email, phone) */
.ct-multi-row {
  display: flex;
  gap: 0.375rem;
  margin-bottom: 0.375rem;
}
.ct-multi-input {
  flex: 1;
}
.ct-multi-type {
  width: 90px;
}
.ct-multi-remove {
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
.ct-multi-remove:hover {
  color: var(--danger);
  border-color: var(--danger);
}

.ct-add-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  background: transparent;
  border: none;
  color: var(--primary);
  font-size: 0.85rem;
  cursor: pointer;
  padding: 0.3rem 0;
  margin-bottom: 0.75rem;
}
.ct-add-btn:hover {
  text-decoration: underline;
}

.ct-edit-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.5rem;
}
.ct-btn-cancel {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}
.ct-btn-cancel:hover {
  border-color: var(--text-muted);
}
</style>
