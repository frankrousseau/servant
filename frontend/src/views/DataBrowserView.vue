<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import ComboBox from '../components/ComboBox.vue'
import { useApi } from '../composables/useApi'
import { useSocket, debounce } from '../composables/useSocket'
import type { Entry, PaginationMeta } from '../types'
import { relativeTime } from '../types'
import { formatDateTime } from '../lib/datetime'
import KindIcon from '../components/KindIcon.vue'
import { useConfirm } from '../composables/useConfirm'

const api = useApi()
const route = useRoute()
const router = useRouter()

const entries = ref<Entry[]>([])
const meta = ref<PaginationMeta>({
  page: 1,
  per_page: 50,
  total: 0,
  total_pages: 1
})
const loading = ref(true)

// Filters
const kinds = ref<string[]>([])
const sources = ref<string[]>([])

const kindOptions = computed(() => [
  { value: '', label: 'All kinds' },
  ...kinds.value
])
const sourceOptions = computed(() => [
  { value: '', label: 'All sources' },
  ...sources.value
])
const filterKind = ref((route.query.kind as string) || '')
const filterSource = ref((route.query.source as string) || '')
const filterDateFrom = ref('')
const filterDateTo = ref('')
const page = ref(1)

// Detail
const selectedEntry = ref<Entry | null>(null)
const showDetail = ref(false)

function closeDetail() {
  showDetail.value = false
  router.replace({ query: {} })
}

// Create/Edit modal
const showModal = ref(false)
const editingEntry = ref<Entry | null>(null)
const formKind = ref('')
const formSource = ref('')
const formTitle = ref('')
const formData = ref('{}')
const saving = ref(false)
const formError = ref<string | null>(null)
const pageError = ref<string | null>(null)

function errMessage(e: unknown, fallback: string): string {
  return e instanceof Error && e.message ? e.message : fallback
}

// Real-time. Debounced so a burst of entry events (e.g. a connector sync) or the
// aggregated entries_changed signal refetches the page once, not per row.
const { onEntryChange, onBulkChange } = useSocket()
const refresh = debounce(() => fetchEntries())
onEntryChange(refresh)
onBulkChange(refresh)

async function fetchFilters() {
  try {
    const [kindsRes, sourcesRes] = await Promise.all([
      api.get<{ data: string[] }>('/api/entries/kinds'),
      api.get<{ data: string[] }>('/api/entries/sources')
    ])
    kinds.value = kindsRes.data
    sources.value = sourcesRes.data
  } catch {
    // ignore
  }
}

async function fetchEntries() {
  loading.value = true
  try {
    // Newest-created first: the default occurred_at sort floats future
    // events (calendar) to the top, unrelated to when data actually landed.
    const params: Record<string, string> = {
      page: page.value.toString(),
      per_page: '50',
      sort: 'inserted_at'
    }
    if (filterKind.value) params.kind = filterKind.value
    if (filterSource.value) params.source = filterSource.value
    if (filterDateFrom.value) params.from = filterDateFrom.value + 'T00:00:00Z'
    if (filterDateTo.value) params.to = filterDateTo.value + 'T23:59:59Z'

    const res = await api.get<{ data: Entry[]; meta: PaginationMeta }>(
      '/api/entries',
      params
    )
    entries.value = res.data
    meta.value = res.meta
    pageError.value = null
  } catch (e) {
    entries.value = []
    pageError.value = errMessage(e, 'Failed to load entries')
  } finally {
    loading.value = false
  }
}

function openDetail(entry: Entry) {
  selectedEntry.value = entry
  showDetail.value = true
}

function openCreate() {
  editingEntry.value = null
  formKind.value = ''
  formSource.value = 'manual'
  formTitle.value = ''
  formData.value = '{}'
  formError.value = null
  showModal.value = true
}

function openEdit(entry: Entry) {
  editingEntry.value = entry
  formKind.value = entry.kind
  formSource.value = entry.source
  formTitle.value = entry.title || ''
  formData.value = JSON.stringify(entry.data, null, 2)
  formError.value = null
  showModal.value = true
}

async function saveEntry() {
  formError.value = null

  // Validate the JSON up front so an invalid payload shows a message instead of
  // silently freezing the modal.
  let data: unknown
  try {
    data = JSON.parse(formData.value)
  } catch {
    formError.value = 'The Data field is not valid JSON.'
    return
  }

  saving.value = true
  try {
    const body = {
      kind: formKind.value,
      source: formSource.value,
      title: formTitle.value,
      data
    }

    if (editingEntry.value) {
      await api.put(`/api/entries/${editingEntry.value.id}`, body)
    } else {
      await api.post('/api/entries', body)
    }

    showModal.value = false
    await fetchEntries()
    await fetchFilters()
  } catch (e) {
    formError.value = errMessage(e, 'Failed to save entry')
  } finally {
    saving.value = false
  }
}

const { ask } = useConfirm()

// Human description of the active filter, for the confirm message.
const activeFilterLabel = computed(() => {
  const parts: string[] = []
  if (filterKind.value) parts.push(`kind "${filterKind.value}"`)
  if (filterSource.value) parts.push(`source "${filterSource.value}"`)
  if (filterDateFrom.value || filterDateTo.value) parts.push('the date range')
  return parts.join(' and ')
})

async function deleteAllFiltered() {
  if (!filterKind.value && !filterSource.value) return
  const ok = await ask({
    message: `Delete all ${meta.value.total} entries matching ${activeFilterLabel.value}? This cannot be undone.`,
    danger: true
  })
  if (!ok) return
  try {
    // Mirror fetchEntries exactly: what you see is what gets deleted.
    const params = new URLSearchParams()
    if (filterKind.value) params.set('kind', filterKind.value)
    if (filterSource.value) params.set('source', filterSource.value)
    if (filterDateFrom.value)
      params.set('from', filterDateFrom.value + 'T00:00:00Z')
    if (filterDateTo.value) params.set('to', filterDateTo.value + 'T23:59:59Z')
    await api.del(`/api/entries?${params.toString()}`)
    filterKind.value = ''
    filterSource.value = ''
    await fetchFilters()
  } catch (e) {
    pageError.value = errMessage(e, 'Failed to delete entries')
  }
}

async function deleteEntry(entry: Entry) {
  const ok = await ask({
    message: `Delete "${entry.title || entry.kind}" entry?`
  })
  if (!ok) return
  try {
    await api.del(`/api/entries/${entry.id}`)
    showDetail.value = false
    selectedEntry.value = null
    await fetchEntries()
    await fetchFilters()
  } catch (e) {
    pageError.value = errMessage(e, 'Failed to delete entry')
  }
}

function goToPage(p: number) {
  page.value = p
}

const pageRange = computed(() => {
  const total = meta.value.total_pages
  const current = meta.value.page
  const range: number[] = []
  const start = Math.max(1, current - 2)
  const end = Math.min(total, current + 2)
  for (let i = start; i <= end; i++) range.push(i)
  return range
})

function formatData(data: Record<string, unknown>): string {
  return JSON.stringify(data, null, 2)
}

// Watch filters -> reset to page 1. When already on page 1 the page watcher
// won't fire, so fetch explicitly then; otherwise let the page watcher fetch
// (avoids two concurrent requests for the same params).
watch([filterKind, filterSource, filterDateFrom, filterDateTo], () => {
  if (page.value === 1) {
    fetchEntries()
  } else {
    page.value = 1
  }
})
watch(page, fetchEntries)

// Handle deep link to entry detail
watch(
  () => route.query.entry,
  async entryId => {
    if (entryId) {
      try {
        const res = await api.get<{ data: Entry }>(`/api/entries/${entryId}`)
        selectedEntry.value = res.data
        showDetail.value = true
      } catch {
        // ignore
      }
    }
  },
  { immediate: true }
)

// Sync kind filter from route query
watch(
  () => route.query.kind,
  kind => {
    if (kind && kind !== filterKind.value) {
      filterKind.value = kind as string
    }
  }
)

onMounted(() => {
  fetchFilters()
  fetchEntries()
})
</script>

<template>
  <div class="view">
    <div class="browser-head">
      <div class="view-header">
        <h1>Data Browser</h1>
        <button @click="openCreate">+ New Entry</button>
      </div>

      <p v-if="pageError" class="error-banner" role="alert">
        {{ pageError }}
        <button
          class="error-banner-close"
          @click="pageError = null"
          aria-label="Dismiss"
        >
          ×
        </button>
      </p>

      <!-- Filters -->
      <div class="filters">
        <ComboBox
          v-model="filterKind"
          class="db-filter capitalize"
          :options="kindOptions"
        />
        <ComboBox
          v-model="filterSource"
          class="db-filter capitalize"
          :options="sourceOptions"
        />
        <input v-model="filterDateFrom" type="date" title="From date" />
        <input v-model="filterDateTo" type="date" title="To date" />
        <span class="filter-count" v-if="!loading"
          >{{ meta.total }} entries</span
        >
        <button
          v-if="(filterKind || filterSource) && meta.total > 0 && !loading"
          class="small danger"
          @click="deleteAllFiltered"
        >
          Delete all
        </button>
      </div>

      <div v-if="meta.total_pages > 1 && !loading" class="pagination">
        <button
          class="small"
          :disabled="meta.page <= 1"
          @click.stop="goToPage(meta.page - 1)"
        >
          &lsaquo;
        </button>
        <button
          v-for="p in pageRange"
          :key="p"
          class="small"
          :class="{ 'page-active': p === meta.page }"
          @click.stop="goToPage(p)"
        >
          {{ p }}
        </button>
        <button
          class="small"
          :disabled="meta.page >= meta.total_pages"
          @click.stop="goToPage(meta.page + 1)"
        >
          &rsaquo;
        </button>
      </div>
    </div>

    <p v-if="loading" class="loading-text">Loading...</p>

    <!-- Entry list -->
    <div v-else-if="entries.length" class="entry-list">
      <div
        v-for="entry in entries"
        :key="entry.id"
        class="entry-row"
        @click="openDetail(entry)"
        v-click-key
        role="button"
        tabindex="0"
      >
        <KindIcon :kind="entry.kind" :size="14" />
        <div class="entry-main">
          <span class="entry-title">
            {{ entry.title || entry.external_id || '(untitled)' }}
          </span>
          <span class="entry-subtitle">
            {{ entry.source }}
            <template v-if="entry.occurred_at">
              &middot; {{ relativeTime(entry.occurred_at) }}
            </template>
          </span>
        </div>
        <span class="entry-kind-badge">{{ entry.kind }}</span>
      </div>
    </div>

    <p v-else class="empty">No entries found.</p>

    <!-- Detail panel -->
    <div
      v-if="showDetail && selectedEntry"
      class="modal-overlay"
      @click.self="closeDetail"
    >
      <div class="detail-panel">
        <div class="detail-header">
          <div>
            <KindIcon :kind="selectedEntry.kind" :size="18" />
            <h2>{{ selectedEntry.title || selectedEntry.kind }}</h2>
          </div>
          <button class="small" @click="closeDetail">Close</button>
        </div>

        <div class="detail-meta">
          <div class="detail-meta-item">
            <span class="detail-label">Kind</span>
            <span class="detail-value">{{ selectedEntry.kind }}</span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-label">Source</span>
            <span class="detail-value">{{ selectedEntry.source }}</span>
          </div>
          <div v-if="selectedEntry.external_id" class="detail-meta-item">
            <span class="detail-label">External ID</span>
            <span class="detail-value mono">{{
              selectedEntry.external_id
            }}</span>
          </div>
          <div v-if="selectedEntry.occurred_at" class="detail-meta-item">
            <span class="detail-label">Occurred</span>
            <span class="detail-value">
              {{ formatDateTime(selectedEntry.occurred_at) }}
            </span>
          </div>
          <div class="detail-meta-item">
            <span class="detail-label">Created</span>
            <span class="detail-value">
              {{ formatDateTime(selectedEntry.inserted_at) }}
            </span>
          </div>
        </div>

        <div class="detail-data">
          <h3>Data</h3>
          <pre>{{ formatData(selectedEntry.data) }}</pre>
        </div>

        <div
          v-if="
            selectedEntry.metadata && Object.keys(selectedEntry.metadata).length
          "
          class="detail-data"
        >
          <h3>Metadata</h3>
          <pre>{{ formatData(selectedEntry.metadata) }}</pre>
        </div>

        <div class="detail-actions">
          <button class="small" @click="openEdit(selectedEntry!)">Edit</button>
          <button class="small danger" @click="deleteEntry(selectedEntry!)">
            Delete
          </button>
        </div>
      </div>
    </div>

    <!-- Create/Edit Modal -->
    <div v-if="showModal" class="modal-overlay" @click.self="showModal = false">
      <div class="modal">
        <h2>{{ editingEntry ? 'Edit Entry' : 'New Entry' }}</h2>
        <form @submit.prevent="saveEntry">
          <div class="field">
            <label>Kind</label>
            <input
              v-model="formKind"
              placeholder="e.g. transaction, article, note"
              required
            />
          </div>
          <div class="field">
            <label>Source</label>
            <input v-model="formSource" required />
          </div>
          <div class="field">
            <label>Title</label>
            <input v-model="formTitle" placeholder="Optional title" />
          </div>
          <div class="field">
            <label>Data (JSON)</label>
            <textarea v-model="formData" rows="8"></textarea>
          </div>
          <p v-if="formError" class="form-error" role="alert">
            {{ formError }}
          </p>
          <div class="modal-actions">
            <button type="button" @click="showModal = false">Cancel</button>
            <button type="submit" :disabled="saving">
              {{ saving ? 'Saving...' : 'Save' }}
            </button>
          </div>
        </form>
      </div>
    </div>
  </div>
</template>

<style scoped>
.loading-text {
  color: var(--text-muted);
}

.error-banner {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75rem;
  background: rgba(240, 108, 108, 0.12);
  border: 1px solid var(--danger);
  color: var(--danger);
  padding: 0.6rem 0.85rem;
  border-radius: 6px;
  margin-bottom: 1rem;
}

.error-banner-close {
  background: none;
  border: none;
  color: inherit;
  font-size: 1.1rem;
  line-height: 1;
  cursor: pointer;
  padding: 0;
}

.form-error {
  color: var(--danger);
  margin: 0 0 0.5rem;
  font-size: 0.9rem;
}

/* Sticky header: negative margin swallows the content's 2rem top padding so
   the opaque background reaches the viewport edge when pinned. */
.browser-head {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--bg);
  padding: 2rem 0 0.75rem;
  margin: -2rem 0 1rem;
  border-bottom: 1px solid var(--border);
}

.filters {
  display: flex;
  gap: 0.75rem;
  flex-wrap: wrap;
  align-items: center;
}

.db-filter {
  min-width: 140px;
  width: auto;
}

.capitalize {
  text-transform: capitalize;
}

.filters input[type='date'] {
  width: auto;
}

.filter-count {
  font-size: 1rem;
  color: var(--text-muted);
  margin-left: auto;
}

/* Entry list */
.entry-list {
  display: flex;
  flex-direction: column;
}

.entry-row {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.65rem 0.5rem;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  transition: background 0.1s;
  border-radius: var(--radius);
}

.entry-row:hover {
  background: var(--bg-hover);
}

.entry-icon {
  width: 28px;
  height: 28px;
  border-radius: var(--radius);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1rem;
  color: #fff;
  flex-shrink: 0;
}

.entry-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.entry-title {
  font-size: 1rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.entry-subtitle {
  font-size: 0.875rem;
  color: var(--text-muted);
}

.entry-kind-badge {
  font-size: 0.9rem;
  color: var(--text-muted);
  background: var(--bg-hover);
  padding: 0.15rem 0.5rem;
  border-radius: var(--radius);
  white-space: nowrap;
}

/* Pagination */
.pagination {
  display: flex;
  gap: 0.35rem;
  justify-content: center;
  padding: 0.5rem 0 0;
}

/* Buttons are primary-filled by default, so a filled "current page" looked
   exactly like its neighbours. The row is neutral, the current page is the
   only filled one. */
.pagination button {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  min-width: 2.1rem;
}

.pagination button:hover:not(:disabled) {
  background: var(--bg-hover);
  color: var(--text);
}

.pagination .page-active,
.pagination .page-active:hover {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
  font-weight: 600;
}

/* Detail panel */
.detail-panel {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.5rem;
  width: 100%;
  max-width: 600px;
  max-height: 85vh;
  overflow-y: auto;
}

.detail-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 1rem;
}

.detail-header > div {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.detail-header h2 {
  margin: 0;
  font-size: 1.15rem;
}

.detail-icon {
  width: 32px;
  height: 32px;
  border-radius: var(--radius);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 1rem;
  color: #fff;
  flex-shrink: 0;
}

.detail-meta {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75rem;
  margin-bottom: 1.25rem;
}

.detail-meta-item {
  display: flex;
  flex-direction: column;
}

.detail-label {
  font-size: 0.9rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.detail-value {
  font-size: 1rem;
}

.detail-value.mono {
  font-family: monospace;
  font-size: 1rem;
  word-break: break-all;
}

.detail-data {
  margin-bottom: 1rem;
}

.detail-data h3 {
  font-size: 1rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.5rem;
}

.detail-data pre {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.75rem;
  font-size: 1rem;
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-word;
  max-height: 300px;
  overflow-y: auto;
}

.detail-actions {
  display: flex;
  gap: 0.5rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
}
</style>
