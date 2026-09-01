<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  ArrowLeft,
  Check,
  Copy,
  LoaderCircle,
  RefreshCw,
  ToggleLeft,
  ToggleRight,
  Trash2,
  Upload,
  X
} from 'lucide-vue-next'

import ComboBox from '../components/ComboBox.vue'

import {
  connectorLogs,
  deleteConnector as removeConnector,
  enableBankingAuthUrl,
  getConnector,
  importConnectorFile,
  startConnector,
  stopConnector,
  syncConnector,
  updateConnector
} from '../api/connectors'
import { getConnectorDef } from '../connectors'
import { useConfirm } from '../composables/useConfirm'
import { SCHEDULE_LABELS } from '../lib/connectors'
import { formatDate, formatDateTime, relativeTime } from '../lib/datetime'
import { useAuthStore } from '../stores/auth'
import type { ConnectorConfig, Schedule, SyncLog } from '../types'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const connector = ref<ConnectorConfig | null>(null)
const logs = ref<SyncLog[]>([])
const loading = ref(true)
const logsLoading = ref(true)
const syncing = ref(false)
const actionFeedback = ref('')

const connectorDef = computed(() =>
  connector.value ? getConnectorDef(connector.value.connector_type) : null
)

const copiedId = ref<string | null>(null)
function copyError(text: string, id: string) {
  navigator.clipboard.writeText(text)
  copiedId.value = id
  setTimeout(() => (copiedId.value = null), 1500)
}

// CSV upload
const uploading = ref(false)
const uploadResult = ref<{ imported: number; skipped: number } | null>(null)
const uploadError = ref('')

const importableTypes: Record<
  string,
  { accept: string; label: string; items: string }
> = {
  bank_csv: { accept: '.csv', label: 'CSV', items: 'transactions' },
  ical: { accept: '.ics,.ical', label: 'iCal (.ics)', items: 'events' },
  vcard: { accept: '.vcf,.vcard', label: 'vCard (.vcf)', items: 'contacts' },
  apple_health: {
    accept: '.xml',
    label: 'Apple Health export (XML)',
    items: 'records'
  }
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

  try {
    uploadResult.value = await importConnectorFile(
      connectorId.value,
      file,
      auth.token
    )
    await fetchConnector()
    await fetchLogs()
  } catch (err: any) {
    uploadError.value = err.message || 'Upload failed'
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
    window.location.href = await enableBankingAuthUrl(
      connectorId.value,
      ebRedirectUrl
    )
  } catch (err) {
    ebError.value =
      err instanceof Error ? err.message : 'Could not start the bank connection'
    ebConnecting.value = false
  }
}

// `silent` skips the loading toggle so background polling doesn't tear the whole
// view down to a "Loading…" state every 2s (and drop focus on the title).
async function fetchConnector(silent = false) {
  if (!silent) loading.value = true
  try {
    connector.value = await getConnector(connectorId.value)
  } catch {
    if (!silent) connector.value = null
  } finally {
    if (!silent) loading.value = false
  }
}

async function fetchLogs(silent = false) {
  if (!silent) logsLoading.value = true
  try {
    logs.value = await connectorLogs(connectorId.value)
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
    await updateConnector(connectorId.value, { name: newName })
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
    await syncConnector(connectorId.value)
  } catch {
    // Connector may not be running, try start first
    try {
      await startConnector(connectorId.value)
      await syncConnector(connectorId.value)
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
  (Object.keys(SCHEDULE_LABELS) as Schedule[]).map(schedule => ({
    value: schedule,
    label: SCHEDULE_LABELS[schedule]
  }))
)

function onScheduleChange(value: string) {
  void updateSchedule(value as Schedule)
}

async function updateSchedule(schedule: Schedule) {
  if (!connector.value) return
  try {
    await updateConnector(connectorId.value, { schedule })
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
    await updateConnector(connectorId.value, { enabled: newState })
    // Start or stop the worker accordingly
    if (newState) {
      await startConnector(connectorId.value)
    } else {
      await stopConnector(connectorId.value)
    }
    connector.value.enabled = newState
    showFeedback(newState ? 'Connector enabled' : 'Connector disabled')
  } catch {
    showFeedback('Failed to update')
  }
}

// ----- editable configuration -----

const configFields = computed(() => connectorDef.value?.configFields || [])
const configForm = ref<Record<string, string>>({})
const configSaving = ref(false)
const configErrorMsg = ref('')

function resetConfigForm() {
  const values: Record<string, string> = {}
  for (const field of configFields.value) {
    const raw = connector.value?.config[field.key]
    values[field.key] = raw === null || raw === undefined ? '' : String(raw)
  }
  configForm.value = values
}

async function saveConfig() {
  if (!connector.value) return
  configSaving.value = true
  configErrorMsg.value = ''
  try {
    // Start from the stored config: untouched keys (sync cursors, hint
    // values) survive the wholesale replace, and redacted secrets round-trip
    // as their marker, which the backend swaps back for the stored value.
    const merged: Record<string, unknown> = { ...connector.value.config }
    for (const field of configFields.value) {
      const value = (configForm.value[field.key] || '').trim()
      if (!value) delete merged[field.key]
      else merged[field.key] = field.type === 'number' ? Number(value) : value
    }
    await updateConnector(connectorId.value, { config: merged })
    await fetchConnector(true)
    resetConfigForm()
    showFeedback('Configuration saved')
  } catch (err) {
    configErrorMsg.value =
      err instanceof Error ? err.message : 'Failed to save the configuration'
  } finally {
    configSaving.value = false
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
    await removeConnector(connectorId.value)
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

onMounted(async () => {
  await fetchConnector()
  resetConfigForm()
  fetchLogs()
})
</script>

<template>
  <div class="view">
    <div class="view-header">
      <div class="back-title">
        <router-link
          v-autofocus
          to="/connectors"
          class="back-link"
          aria-label="Back to sources"
        >
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
          <span class="connector-error-text">{{ connector.error }}</span>
          <button
            class="copy-error-btn"
            @click.stop="copyError(connector.error!, 'main')"
            :title="copiedId === 'main' ? 'Copied!' : 'Copy error'"
            :aria-label="copiedId === 'main' ? 'Copied' : 'Copy error'"
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
            Imported {{ uploadResult.imported }} {{ importConfig.items
            }}<template v-if="uploadResult.skipped"
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

        <form
          v-if="configFields.length"
          class="config-form"
          @submit.prevent="saveConfig"
        >
          <div
            v-for="field in configFields"
            :key="field.key"
            class="config-field"
          >
            <label :for="`cfg-${field.key}`">
              {{ field.label }}
              <span v-if="!field.required" class="config-optional"
                >optional</span
              >
            </label>
            <ComboBox
              v-if="field.type === 'select' && field.options"
              v-model="configForm[field.key]"
              :options="field.options"
            />
            <textarea
              v-else-if="field.type === 'textarea'"
              :id="`cfg-${field.key}`"
              v-model="configForm[field.key]"
              class="config-textarea"
              rows="5"
              :placeholder="field.placeholder"
              spellcheck="false"
            ></textarea>
            <input
              v-else
              :id="`cfg-${field.key}`"
              v-model="configForm[field.key]"
              :type="field.type"
              :placeholder="field.placeholder"
            />
          </div>
          <p v-if="configErrorMsg" class="upload-result msg-error">
            {{ configErrorMsg }}
          </p>
          <button
            type="submit"
            class="action-btn action-btn--primary config-save"
            :disabled="configSaving"
          >
            {{ configSaving ? 'Saving...' : 'Save configuration' }}
          </button>
        </form>

        <h3 v-if="isImportable || isEnableBanking || configFields.length">
          Settings
        </h3>
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
              <span v-if="log.error" class="log-error">
                <span class="log-error-text">{{ log.error }}</span>
                <button
                  class="copy-error-btn"
                  @click.stop="copyError(log.error!, `log-${log.id}`)"
                  :title="
                    copiedId === `log-${log.id}` ? 'Copied!' : 'Copy error'
                  "
                  :aria-label="
                    copiedId === `log-${log.id}` ? 'Copied' : 'Copy error'
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
  flex-shrink: 0;
  width: 24px;
  height: 24px;
  padding: 0;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  cursor: pointer;
  border-radius: 6px;
  transition:
    color 0.15s,
    border-color 0.15s;
}

.copy-error-btn:hover {
  color: var(--primary);
  border-color: var(--primary);
  background: transparent;
}

.connector-error {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  color: var(--danger);
  margin: 0.5rem 0;
  padding: 0.5rem 0.75rem;
  background: color-mix(in srgb, var(--danger) 10%, transparent);
  border: 1px solid color-mix(in srgb, var(--danger) 35%, transparent);
  border-radius: var(--radius);
}
/* Error payloads are API messages: mono, and free to wrap however long. */
.connector-error-text {
  flex: 1;
  min-width: 0;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  overflow-wrap: anywhere;
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
  padding: 0.35rem 0.8rem;
  font-size: 0.85rem;
  font-weight: 500;
  border-radius: var(--control-radius);
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
  background: color-mix(in srgb, var(--danger) 8%, transparent);
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

/* ----- Configuration form ----- */
.config-form {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  max-width: 480px;
  margin-bottom: 1.25rem;
}
.config-field {
  display: flex;
  flex-direction: column;
  gap: 0.3rem;
}
.config-field label {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.config-optional {
  font-size: 0.75rem;
  color: var(--text-muted);
  opacity: 0.7;
  margin-left: 0.3rem;
}
.config-textarea {
  font-family: var(--font-mono);
  font-size: 0.85rem;
  resize: vertical;
}
.config-save {
  align-self: flex-start;
}

.config-pre {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.75rem;
  font-family: var(--font-mono);
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
  background: color-mix(in srgb, var(--success) 15%, transparent);
  color: var(--success);
}

.log-icon-failed {
  background: color-mix(in srgb, var(--danger) 15%, transparent);
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

.log-error {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  min-width: 0;
}
.log-error-text {
  font-family: var(--font-mono);
  font-size: 0.82rem;
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
  background: color-mix(in srgb, var(--success) 10%, transparent);
}

.msg-error {
  color: var(--danger);
  background: color-mix(in srgb, var(--danger) 10%, transparent);
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
