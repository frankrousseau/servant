<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  Upload,
  ArrowLeft,
  Check,
  X,
  LoaderCircle,
  Copy,
  RefreshCw,
  ToggleLeft,
  ToggleRight,
  Trash2
} from 'lucide-vue-next'

import ComboBox from '../components/ComboBox.vue'

import { useApi } from '../composables/useApi'
import { useAuthStore } from '../stores/auth'
import type { ConnectorConfig, SyncLog, Schedule } from '../types'
import { relativeTime } from '../lib/datetime'
import { SCHEDULE_LABELS } from '../lib/connectors'
import { formatDate, formatDateTime } from '../lib/datetime'
import { getConnectorDef } from '../connectors'
import { useConfirm } from '../composables/useConfirm'

const copiedId = ref<string | null>(null)
function copyError(text: string, id: string) {
  navigator.clipboard.writeText(text)
  copiedId.value = id
  setTimeout(() => (copiedId.value = null), 1500)
}

const connectorDef = computed(() =>
  connector.value ? getConnectorDef(connector.value.connector_type) : null
)

const route = useRoute()
const router = useRouter()
const api = useApi()

const connector = ref<ConnectorConfig | null>(null)
const logs = ref<SyncLog[]>([])
const auth = useAuthStore()
const loading = ref(true)
const logsLoading = ref(true)
const syncing = ref(false)
const actionFeedback = ref('')

// CSV upload
const uploading = ref(false)
const uploadResult = ref<{ imported: number; skipped: number } | null>(null)
const uploadError = ref('')

const importableTypes: Record<string, { accept: string; label: string }> = {
  bank_csv: { accept: '.csv', label: 'CSV' },
  ical: { accept: '.ics,.ical', label: 'iCal (.ics)' },
  vcard: { accept: '.vcf,.vcard', label: 'vCard (.vcf)' },
  apple_health: { accept: '.xml', label: 'Apple Health export (XML)' }
}

const isImportable = computed(() =>
  connector.value ? connector.value.connector_type in importableTypes : false
)
const isImportOnly = computed(
  () => connector.value?.connector_type === 'bank_csv'
)
const importConfig = computed(() =>
  connector.value ? importableTypes[connector.value.connector_type] : null
)

async function uploadCSV(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file || !connector.value) return

  uploading.value = true
  uploadResult.value = null
  uploadError.value = ''

  const formData = new FormData()
  formData.append('file', file)

  try {
    const res = await fetch(`/api/connectors/${connectorId.value}/import`, {
      method: 'POST',
      headers: auth.token ? { Authorization: `Bearer ${auth.token}` } : {},
      body: formData
    })

    const data = await res.json()

    if (res.ok) {
      uploadResult.value = { imported: data.imported, skipped: data.skipped }
      await fetchConnector()
      await fetchLogs()
    } else {
      uploadError.value = data.error || 'Import failed'
    }
  } catch (e: any) {
    uploadError.value = e.message || 'Upload failed'
  } finally {
    uploading.value = false
    input.value = ''
  }
}

const connectorId = computed(() => route.params.id as string)

// ----- Enable Banking consent flow -----

const isEnableBanking = computed(
  () => connector.value?.connector_type === 'enable_banking'
)
// Fixed callback registered once in the Enable Banking application.
const ebRedirectUrl = `${window.location.origin}/connectors/eb-callback`
const ebConnecting = ref(false)
const ebError = ref('')

const ebAccounts = computed(
  () => (connector.value?.config.accounts as { name?: string }[]) || []
)
const ebValidUntil = computed(
  () => connector.value?.config.valid_until as string | undefined
)
const ebConnected = computed(() => ebAccounts.value.length > 0)

async function ebConnect() {
  ebConnecting.value = true
  ebError.value = ''
  try {
    const res = await api.post<{ url: string }>(
      `/api/connectors/${connectorId.value}/enable_banking/auth_url`,
      { redirect_url: ebRedirectUrl }
    )
    window.location.href = res.url
  } catch (e) {
    ebError.value =
      e instanceof Error ? e.message : 'Could not start the bank connection'
    ebConnecting.value = false
  }
}

// `silent` skips the loading toggle so background polling doesn't tear the whole
// view down to a "Loading…" state every 2s (and drop focus on the title).
async function fetchConnector(silent = false) {
  if (!silent) loading.value = true
  try {
    const res = await api.get<{ data: ConnectorConfig }>(
      `/api/connectors/${connectorId.value}`
    )
    connector.value = res.data
  } catch {
    if (!silent) connector.value = null
  } finally {
    if (!silent) loading.value = false
  }
}

async function fetchLogs(silent = false) {
  if (!silent) logsLoading.value = true
  try {
    const res = await api.get<{ data: SyncLog[] }>(
      `/api/connectors/${connectorId.value}/logs`
    )
    logs.value = res.data
  } catch {
    if (!silent) logs.value = []
  } finally {
    if (!silent) logsLoading.value = false
  }
}

async function saveName(event: Event) {
  const el = event.target as HTMLInputElement
  const newName = el.value.trim()
  if (!connector.value || newName === (connector.value.name || '')) return

  try {
    await api.put(`/api/connectors/${connectorId.value}`, { name: newName })
    connector.value.name = newName
  } catch {
    // Revert the field to the last saved value on failure.
    el.value = connector.value.name || ''
  }
}

async function syncNow() {
  syncing.value = true
  // Clear current error immediately for visual feedback
  if (connector.value) {
    connector.value.error = null
  }
  try {
    await api.post(`/api/connectors/${connectorId.value}/sync`)
  } catch {
    // Connector may not be running, try start first
    try {
      await api.post(`/api/connectors/${connectorId.value}/start`)
      await api.post(`/api/connectors/${connectorId.value}/sync`)
    } catch {
      // ignore
    }
  }
  // Poll for completion
  pollSync()
}

const pollTimer = ref<ReturnType<typeof setInterval> | null>(null)

function stopPolling() {
  if (pollTimer.value) {
    clearInterval(pollTimer.value)
    pollTimer.value = null
  }
}

function pollSync() {
  stopPolling()
  let attempts = 0
  pollTimer.value = setInterval(async () => {
    attempts++
    await fetchLogs(true)
    await fetchConnector(true)
    // Stop polling when the latest log is no longer "running", or after 60s
    const latest = logs.value[0]
    if (!latest || latest.status !== 'running' || attempts >= 30) {
      stopPolling()
      syncing.value = false
    }
  }, 2000)
}

onUnmounted(stopPolling)

function showFeedback(msg: string) {
  actionFeedback.value = msg
  setTimeout(() => (actionFeedback.value = ''), 2500)
}

const scheduleOptions = computed(() =>
  (Object.keys(SCHEDULE_LABELS) as Schedule[]).map(s => ({
    value: s,
    label: SCHEDULE_LABELS[s]
  }))
)

function onScheduleChange(v: string) {
  void updateSchedule(v as Schedule)
}

async function updateSchedule(schedule: Schedule) {
  if (!connector.value) return
  try {
    await api.put(`/api/connectors/${connectorId.value}`, { schedule })
    connector.value.schedule = schedule
  } catch {
    // ignore
  }
}

async function toggleEnabled() {
  if (!connector.value) return
  const newState = !connector.value.enabled
  try {
    // Update the flag in DB
    await api.put(`/api/connectors/${connectorId.value}`, {
      enabled: newState
    })
    // Start or stop the worker accordingly
    if (newState) {
      await api.post(`/api/connectors/${connectorId.value}/start`)
    } else {
      await api.post(`/api/connectors/${connectorId.value}/stop`)
    }
    connector.value.enabled = newState
    showFeedback(newState ? 'Connector enabled' : 'Connector disabled')
  } catch {
    showFeedback('Failed to update')
  }
}

const { ask } = useConfirm()

async function deleteConnector() {
  const ok = await ask({
    title: 'Delete connector',
    message: 'This will delete the connector and all its sync history.'
  })
  if (!ok) return
  try {
    await api.del(`/api/connectors/${connectorId.value}`)
    router.push('/connectors')
  } catch {
    // ignore
  }
}

function duration(log: SyncLog): string {
  if (!log.finished_at) return '-'
  const start = new Date(log.started_at).getTime()
  const end = new Date(log.finished_at).getTime()
  const ms = end - start
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60000).toFixed(1)}m`
}

onMounted(() => {
  fetchConnector()
  fetchLogs()
})
</script>

<template>
  <div class="view">
    <div class="view-header">
      <div class="back-title">
        <router-link to="/connectors" class="back-link">
          <ArrowLeft :size="22" />
        </router-link>
        <div
          v-if="connectorDef"
          class="header-logo"
          v-html="connectorDef.logo"
        ></div>
        <input
          v-if="connector"
          class="editable-name"
          :value="connector.name || ''"
          :placeholder="connectorDef?.name || connector.connector_type"
          @blur="saveName"
          @keydown.enter.prevent="($event.target as HTMLInputElement).blur()"
        />
        <h1 v-else>Connector</h1>
      </div>
    </div>

    <p v-if="loading">Loading...</p>

    <template v-else-if="connector">
      <!-- Info card -->
      <section class="detail-card">
        <div class="detail-grid">
          <div class="detail-item">
            <span class="detail-label">Status</span>
            <span v-if="isImportOnly" class="detail-val">Manual import</span>
            <span v-else class="detail-val">
              <span
                class="status-dot"
                :class="{ active: connector.enabled, error: connector.error }"
              ></span>
              {{ connector.enabled ? 'Enabled' : 'Disabled' }}
            </span>
          </div>
          <div v-if="!isImportOnly" class="detail-item">
            <span class="detail-label">Schedule</span>
            <ComboBox
              class="inline-select"
              :model-value="connector.schedule"
              :options="scheduleOptions"
              @update:model-value="onScheduleChange"
            />
          </div>
          <div class="detail-item">
            <span class="detail-label">{{
              isImportOnly ? 'Last import' : 'Last sync'
            }}</span>
            <span class="detail-val">
              <template v-if="connector.last_synced_at">
                {{ relativeTime(connector.last_synced_at) }}
                <span class="detail-sub">
                  ({{ formatDateTime(connector.last_synced_at) }})
                </span>
              </template>
              <template v-else>Never</template>
            </span>
          </div>
          <div class="detail-item">
            <span class="detail-label">Created</span>
            <span class="detail-val">
              {{ formatDate(connector.inserted_at) }}
            </span>
          </div>
        </div>

        <div v-if="syncing" class="sync-banner">Syncing...</div>

        <div v-if="connector.error && !syncing" class="connector-error">
          <span>{{ connector.error }}</span>
          <button
            class="copy-error-btn"
            @click.stop="copyError(connector.error!, 'main')"
            :title="copiedId === 'main' ? 'Copied!' : 'Copy error'"
          >
            <Check v-if="copiedId === 'main'" :size="13" />
            <Copy v-else :size="13" />
          </button>
        </div>

        <div class="action-bar">
          <div v-if="!isImportOnly" class="action-group">
            <button
              class="action-btn action-btn--primary"
              @click="syncNow"
              :disabled="syncing"
            >
              <RefreshCw :size="15" :class="{ spin: syncing }" />
              {{ syncing ? 'Syncing...' : 'Sync Now' }}
            </button>
            <button class="action-btn action-btn--ghost" @click="toggleEnabled">
              <ToggleRight v-if="connector.enabled" :size="15" />
              <ToggleLeft v-else :size="15" />
              {{ connector.enabled ? 'Disable' : 'Enable' }}
            </button>
          </div>
          <div v-else class="action-group"></div>
          <button
            class="action-btn action-btn--danger"
            @click="deleteConnector"
          >
            <Trash2 :size="15" /> Delete
          </button>
        </div>
        <Transition name="fade">
          <div v-if="actionFeedback" class="action-feedback">
            <Check :size="14" /> {{ actionFeedback }}
          </div>
        </Transition>
      </section>

      <!-- Config -->
      <section class="detail-card">
        <h2>{{ isImportable ? 'Import' : 'Configuration' }}</h2>

        <!-- CSV Upload zone (bank_csv only) -->
        <div v-if="isImportable && importConfig" class="upload-zone">
          <label class="upload-area" :class="{ uploading }">
            <Upload :size="24" />
            <span v-if="uploading">Importing...</span>
            <span v-else
              >Drop a {{ importConfig.label }} file or click to browse</span
            >
            <input
              type="file"
              :accept="importConfig.accept"
              class="upload-input"
              @change="uploadCSV"
              :disabled="uploading"
            />
          </label>

          <div v-if="uploadResult" class="upload-result msg-success">
            Imported {{ uploadResult.imported }} transactions<template
              v-if="uploadResult.skipped"
              >, {{ uploadResult.skipped }} skipped (duplicates)</template
            >.
          </div>
          <div v-if="uploadError" class="upload-result msg-error">
            {{ uploadError }}
          </div>
        </div>

        <!-- Bank consent flow (enable_banking only) -->
        <div v-if="isEnableBanking" class="eb-zone">
          <p v-if="ebConnected" class="msg-success">
            Connected: {{ ebAccounts.length }} account(s)<template
              v-if="ebValidUntil"
            >
              , consent valid until
              {{ new Date(ebValidUntil).toLocaleDateString() }}</template
            >.
          </p>
          <p v-else class="eb-hint">
            Not connected to the bank yet. Register this redirect URL in your
            Enable Banking application, then connect:
            <code>{{ ebRedirectUrl }}</code>
          </p>
          <button type="button" :disabled="ebConnecting" @click="ebConnect">
            {{
              ebConnecting
                ? 'Redirecting…'
                : ebConnected
                  ? 'Reconnect (renew consent)'
                  : 'Connect bank account'
            }}
          </button>
          <p v-if="ebError" class="upload-result msg-error">{{ ebError }}</p>
        </div>

        <h3 v-if="isImportable || isEnableBanking">Settings</h3>
        <pre class="config-pre">{{
          JSON.stringify(connector.config, null, 2)
        }}</pre>
      </section>

      <!-- Sync history -->
      <section class="detail-card">
        <h2>{{ isImportOnly ? 'Import History' : 'Sync History' }}</h2>
        <p v-if="logsLoading">Loading...</p>
        <div v-else-if="logs.length" class="log-list">
          <div
            v-for="log in logs"
            :key="log.id"
            class="log-row"
            :class="'log-' + log.status"
          >
            <span class="log-icon" :class="'log-icon-' + log.status">
              <Check v-if="log.status === 'completed'" :size="14" />
              <X v-else-if="log.status === 'failed'" :size="14" />
              <LoaderCircle v-else :size="14" class="spin" />
            </span>
            <div class="log-body">
              <span class="log-status">{{ log.status }}</span>
              <span v-if="log.entries_count > 0" class="log-entries">
                {{ log.entries_count }}
                {{ log.entries_count === 1 ? 'entry' : 'entries' }}
              </span>
              <span v-if="log.error" class="log-error-text">
                {{ log.error }}
                <button
                  class="copy-error-btn"
                  @click.stop="copyError(log.error!, `log-${log.id}`)"
                  :title="
                    copiedId === `log-${log.id}` ? 'Copied!' : 'Copy error'
                  "
                >
                  <Check v-if="copiedId === `log-${log.id}`" :size="12" />
                  <Copy v-else :size="12" />
                </button>
              </span>
            </div>
            <div class="log-time">
              <span>{{ relativeTime(log.started_at) }}</span>
              <span class="log-duration">{{ duration(log) }}</span>
            </div>
          </div>
        </div>
        <p v-else class="empty">No sync history yet.</p>

        <button
          v-if="!logsLoading"
          class="small refresh-btn"
          @click="fetchLogs()"
        >
          Refresh
        </button>
      </section>
    </template>

    <p v-else class="empty">Connector not found.</p>
  </div>
</template>

<style scoped>
.back-title {
  display: flex;
  align-items: center;
  gap: 0.85rem;
}

.back-title h1 {
  margin: 0;
}

.back-link {
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-muted);
  text-decoration: none;
  transition: color 0.15s;
}

.back-link:hover {
  color: var(--text);
}

.editable-name {
  outline: none;
  border: none;
  border-bottom: 1px dashed transparent;
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: 1.5rem;
  font-weight: 600;
  padding: 0;
  transition: border-color 0.15s;
  cursor: text;
  min-width: 60px;
}

.editable-name:hover {
  border-bottom-color: var(--border);
}

.editable-name:focus {
  border-bottom-color: var(--primary);
}

.header-logo {
  width: 40px;
  height: 40px;
  flex-shrink: 0;
  border-radius: 8px;
  overflow: hidden;
  background: #000;
}

.header-logo :deep(svg),
.header-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

/* Detail card */
.detail-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.25rem;
  margin-bottom: 1rem;
}

.detail-card h2 {
  margin: 0 0 0.75rem;
}

.detail-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1rem;
  margin-bottom: 0.75rem;
}

.detail-item {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}

.detail-label {
  font-size: 0.9rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.detail-val {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.detail-sub {
  font-size: 0.9rem;
  color: var(--text-muted);
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--text-muted);
  flex-shrink: 0;
}

.status-dot.active {
  background: var(--success);
}

.status-dot.error {
  background: var(--danger);
}

.inline-select {
  width: auto;
}

.sync-banner {
  font-size: 0.9rem;
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.1);
  padding: 0.5rem 0.75rem;
  border-radius: var(--radius);
  margin-bottom: 0.5rem;
  animation: pulse 1.5s ease-in-out infinite;
}

@keyframes pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.6;
  }
}

.copy-error-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: none;
  border: none;
  color: var(--text-muted);
  padding: 0.2rem;
  cursor: pointer;
  border-radius: 4px;
  vertical-align: middle;
  margin-left: 0.25rem;
  transition: color 0.15s;
}

.copy-error-btn:hover {
  color: var(--text);
  background: none;
}

.connector-error {
  display: flex;
  align-items: flex-start;
  gap: 0.25rem;
  color: var(--danger);
  font-size: 0.9rem;
  margin: 0.5rem 0;
  padding: 0.5rem 0.75rem;
  background: rgba(240, 108, 108, 0.1);
  border-radius: var(--radius);
}

.action-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
}

.action-group {
  display: flex;
  gap: 0.375rem;
}

.action-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.45rem 0.85rem;
  font-size: 0.875rem;
  font-weight: 500;
  border-radius: 8px;
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s,
    border-color 0.15s;
  white-space: nowrap;
}

.action-btn--primary {
  background: var(--primary);
  color: var(--primary-contrast);
  border: 1px solid var(--primary);
}

.action-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}

.action-btn--ghost {
  background: transparent;
  color: var(--text-muted);
  border: 1px solid var(--border);
}

.action-btn--ghost:hover {
  color: var(--text);
  border-color: var(--text-muted);
  background: var(--bg-hover);
}

.action-btn--danger {
  background: transparent;
  color: var(--text-muted);
  border: 1px solid var(--border);
}

.action-btn--danger:hover {
  color: var(--danger);
  border-color: var(--danger);
  background: rgba(240, 108, 108, 0.08);
}

.action-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.action-feedback {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-size: 0.85rem;
  color: var(--success);
  padding: 0.35rem 0;
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.3s;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

.config-pre {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.75rem;
  font-family: monospace;
  font-size: 0.9rem;
  white-space: pre-wrap;
  word-break: break-word;
}

/* Log list */
.log-list {
  display: flex;
  flex-direction: column;
}

.log-row {
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
  padding: 0.6rem 0;
  border-bottom: 1px solid var(--border);
}

.log-row:last-child {
  border-bottom: none;
}

.log-icon {
  width: 26px;
  height: 26px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.log-icon-completed {
  background: rgba(92, 201, 138, 0.15);
  color: var(--success);
}

.log-icon-failed {
  background: rgba(240, 108, 108, 0.15);
  color: var(--danger);
}

.log-icon-running {
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
}

.spin {
  animation: spin 1.2s linear infinite;
}

@keyframes spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

.log-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}

.log-status {
  font-weight: 500;
  text-transform: capitalize;
}

.log-entries {
  font-size: 0.9rem;
  color: var(--text-muted);
}

.log-error-text {
  display: inline-flex;
  align-items: center;
  font-size: 0.9rem;
  color: var(--danger);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.log-time {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  font-size: 0.9rem;
  color: var(--text-muted);
  white-space: nowrap;
}

.log-duration {
  font-size: 0.9rem;
  color: var(--text-muted);
}

.refresh-btn {
  margin-top: 0.75rem;
}

/* Upload */
.upload-zone {
  margin-bottom: 1rem;
}

.upload-area {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
  padding: 2rem;
  border: 2px dashed var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  color: var(--text-muted);
  transition:
    border-color 0.15s,
    color 0.15s;
  text-align: center;
}

.upload-area:hover {
  border-color: var(--primary);
  color: var(--text);
}

.upload-area.uploading {
  border-color: var(--primary);
  opacity: 0.7;
  cursor: wait;
}

.upload-input {
  display: none;
}

.upload-result {
  margin-top: 0.75rem;
  padding: 0.5rem 0.75rem;
  border-radius: var(--radius);
  font-size: 0.9rem;
}

.msg-success {
  color: var(--success);
  background: rgba(92, 201, 138, 0.1);
}

.msg-error {
  color: var(--danger);
  background: rgba(240, 108, 108, 0.1);
}

/* Enable Banking consent flow */
.eb-zone {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.75rem;
  margin-bottom: 1.25rem;
}

.eb-hint {
  color: var(--text-muted);
  font-size: 0.9rem;
  margin: 0;
}

.eb-hint code {
  display: block;
  margin-top: 0.35rem;
  font-size: 0.85rem;
  color: var(--text);
  background: var(--bg-hover);
  padding: 0.25rem 0.5rem;
  border-radius: var(--radius);
  user-select: all;
}
</style>
