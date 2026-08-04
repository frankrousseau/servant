<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'

import { useApi } from '../composables/useApi'
import { utcToZonedParts } from '../lib/datetime'
import { formatFileSize } from '../lib/filesize'

interface SystemStats {
  cpu: {
    cores: number | string
    schedulers: number
    load: {
      avg1: number | null
      avg5: number | null
      avg15: number | null
    } | null
  }
  memory: {
    total_bytes: number | null
    available_bytes: number | null
    cgroup_limit_bytes: number | null
    cgroup_used_bytes: number | null
  }
  server: {
    os_pid: string
    rss_bytes: number | null
    beam_memory_bytes: number
    process_count: number
    uptime_seconds: number
  }
  workers: Array<{
    user_id: string
    config_id: string
    connector_type: string | null
    name: string | null
    memory_bytes: number | null
    message_queue_len: number | null
  }>
  disk: {
    volume: {
      total_bytes: number
      used_bytes: number
      available_bytes: number
      mount: string
    } | null
    data_bytes: number | null
    database_bytes: number | null
  }
}

interface AccessLog {
  at: string
  method: string
  path: string
  query: string
  status: number | null
  duration_us: number
  ip: string | null
  user_id: string | null
}

interface ErrorLog {
  at: string
  level: string
  message: string
}

const api = useApi()

type Tab = 'resources' | 'access' | 'errors'
const tab = ref<Tab>('resources')

const TABS: Array<{ id: Tab; label: string }> = [
  { id: 'resources', label: 'Resources' },
  { id: 'access', label: 'Access log' },
  { id: 'errors', label: 'Error log' }
]

const stats = ref<SystemStats | null>(null)
const accessLogs = ref<AccessLog[]>([])
const errorLogs = ref<ErrorLog[]>([])
const loadError = ref('')

async function refresh() {
  loadError.value = ''
  try {
    if (tab.value === 'resources') {
      stats.value = (
        await api.get<{ data: SystemStats }>('/api/audit/system')
      ).data
    } else if (tab.value === 'access') {
      accessLogs.value = (
        await api.get<{ data: AccessLog[] }>('/api/audit/logs')
      ).data
    } else {
      errorLogs.value = (
        await api.get<{ data: ErrorLog[] }>('/api/audit/logs', {
          type: 'error'
        })
      ).data
    }
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load audit data'
  }
}

function selectTab(next: Tab) {
  tab.value = next
  refresh()
}

let timer: ReturnType<typeof setInterval> | null = null
onMounted(() => {
  refresh()
  timer = setInterval(refresh, 5000)
})
onUnmounted(() => {
  if (timer) clearInterval(timer)
})

// ----- resources helpers -----

// In Docker the cgroup limit is the real budget; the host numbers otherwise.
const ramUsed = computed(() => {
  const memory = stats.value?.memory
  if (!memory) return null
  if (memory.cgroup_limit_bytes && memory.cgroup_used_bytes != null)
    return memory.cgroup_used_bytes
  if (memory.total_bytes != null && memory.available_bytes != null)
    return memory.total_bytes - memory.available_bytes
  return null
})
const ramTotal = computed(() => {
  const memory = stats.value?.memory
  return memory?.cgroup_limit_bytes ?? memory?.total_bytes ?? null
})

const pct = (used: number | null, total: number | null) =>
  used != null && total ? Math.min(100, Math.round((used / total) * 100)) : null

const ramPct = computed(() => pct(ramUsed.value, ramTotal.value))

function uptime(seconds: number): string {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days > 0) return `${days}d ${hours}h ${minutes}m`
  if (hours > 0) return `${hours}h ${minutes}m`
  return `${minutes}m`
}

const bytes = (value: number | null | undefined) =>
  value == null ? '-' : formatFileSize(value)

// ----- logs helpers -----

function stamp(iso: string): string {
  const parts = utcToZonedParts(iso)
  return `${parts.date} ${parts.time}`
}

function statusClass(status: number | null): string {
  if (status == null) return ''
  if (status >= 500) return 'au-status--5xx'
  if (status >= 400) return 'au-status--4xx'
  return 'au-status--ok'
}

const ms = (us: number) =>
  us >= 1000 ? `${Math.round(us / 1000)}ms` : `${us}µs`
</script>

<template>
  <div class="view au-view">
    <h1>Audit</h1>

    <div class="au-tabs">
      <button
        v-for="option in TABS"
        :key="option.id"
        class="au-tab"
        :class="{ 'au-tab--active': tab === option.id }"
        @click="selectTab(option.id)"
      >
        {{ option.label }}
      </button>
    </div>

    <p v-if="loadError" class="au-error">{{ loadError }}</p>

    <!-- ===== Resources ===== -->
    <div v-if="tab === 'resources'" class="au-panels">
      <template v-if="stats">
        <section class="au-panel">
          <h2 class="au-panel-title">Machine</h2>
          <div class="au-row">
            <span class="au-label">CPU cores</span>
            <span class="au-value">{{ stats.cpu.cores }}</span>
          </div>
          <div class="au-row" v-if="stats.cpu.load">
            <span class="au-label">Load 1 / 5 / 15 min</span>
            <span class="au-value"
              >{{ stats.cpu.load.avg1 }} / {{ stats.cpu.load.avg5 }} /
              {{ stats.cpu.load.avg15 }}</span
            >
          </div>
          <div class="au-row">
            <span class="au-label">{{
              stats.memory.cgroup_limit_bytes ? 'RAM (container limit)' : 'RAM'
            }}</span>
            <span class="au-value"
              >{{ bytes(ramUsed) }} / {{ bytes(ramTotal) }}</span
            >
          </div>
          <div v-if="ramPct != null" class="au-bar">
            <div class="au-bar-fill" :style="{ width: ramPct + '%' }"></div>
          </div>
        </section>

        <section class="au-panel">
          <h2 class="au-panel-title">Server</h2>
          <div class="au-row">
            <span class="au-label">Memory (RSS)</span>
            <span class="au-value">{{ bytes(stats.server.rss_bytes) }}</span>
          </div>
          <div class="au-row">
            <span class="au-label">BEAM memory</span>
            <span class="au-value">{{
              bytes(stats.server.beam_memory_bytes)
            }}</span>
          </div>
          <div class="au-row">
            <span class="au-label">Erlang processes</span>
            <span class="au-value">{{ stats.server.process_count }}</span>
          </div>
          <div class="au-row">
            <span class="au-label">Uptime</span>
            <span class="au-value">{{
              uptime(stats.server.uptime_seconds)
            }}</span>
          </div>
          <div class="au-row">
            <span class="au-label">OS pid</span>
            <span class="au-value">{{ stats.server.os_pid }}</span>
          </div>
        </section>

        <section class="au-panel">
          <h2 class="au-panel-title">Disk</h2>
          <template v-if="stats.disk.volume">
            <div class="au-row">
              <span class="au-label">Volume {{ stats.disk.volume.mount }}</span>
              <span class="au-value"
                >{{ bytes(stats.disk.volume.used_bytes) }} /
                {{ bytes(stats.disk.volume.total_bytes) }}</span
              >
            </div>
            <div class="au-bar">
              <div
                class="au-bar-fill"
                :style="{
                  width:
                    pct(
                      stats.disk.volume.used_bytes,
                      stats.disk.volume.total_bytes
                    ) + '%'
                }"
              ></div>
            </div>
            <div class="au-row">
              <span class="au-label">Available</span>
              <span class="au-value">{{
                bytes(stats.disk.volume.available_bytes)
              }}</span>
            </div>
          </template>
          <div class="au-row">
            <span class="au-label">Servant data</span>
            <span class="au-value">{{ bytes(stats.disk.data_bytes) }}</span>
          </div>
          <div class="au-row">
            <span class="au-label">Database</span>
            <span class="au-value">{{ bytes(stats.disk.database_bytes) }}</span>
          </div>
        </section>

        <section class="au-panel au-panel--wide">
          <h2 class="au-panel-title">Workers ({{ stats.workers.length }})</h2>
          <p v-if="stats.workers.length === 0" class="au-empty">
            No connector workers running.
          </p>
          <table v-else class="au-table">
            <thead>
              <tr>
                <th>Connector</th>
                <th>Type</th>
                <th class="au-num">Memory</th>
                <th class="au-num">Queue</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="worker in stats.workers" :key="worker.config_id">
                <td>{{ worker.name || worker.config_id }}</td>
                <td>{{ worker.connector_type || '-' }}</td>
                <td class="au-num">{{ bytes(worker.memory_bytes) }}</td>
                <td class="au-num">{{ worker.message_queue_len ?? '-' }}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </template>
      <p v-else-if="!loadError" class="au-empty">Probing system…</p>
    </div>

    <!-- ===== Access log ===== -->
    <div v-else-if="tab === 'access'" class="au-logs">
      <p v-if="accessLogs.length === 0" class="au-empty">
        No requests recorded yet.
      </p>
      <div v-for="(line, index) in accessLogs" :key="index" class="au-line">
        <span class="au-stamp">{{ stamp(line.at) }}</span>
        <span class="au-method">{{ line.method }}</span>
        <span
          class="au-path"
          :title="line.query ? `${line.path}?${line.query}` : line.path"
          >{{ line.path }}</span
        >
        <span class="au-status" :class="statusClass(line.status)">{{
          line.status ?? '-'
        }}</span>
        <span class="au-dur">{{ ms(line.duration_us) }}</span>
        <span class="au-ip">{{ line.ip || '' }}</span>
      </div>
    </div>

    <!-- ===== Error log ===== -->
    <div v-else class="au-logs">
      <p v-if="errorLogs.length === 0" class="au-empty">
        No errors recorded. Quiet night.
      </p>
      <div
        v-for="(line, index) in errorLogs"
        :key="index"
        class="au-line au-line--error"
      >
        <span class="au-stamp">{{ stamp(line.at) }}</span>
        <span class="au-level">{{ line.level.toUpperCase() }}</span>
        <span class="au-msg">{{ line.message }}</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.au-view {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 4rem);
}
.au-tabs {
  display: flex;
  gap: 0.25rem;
  border-bottom: 1px solid var(--border);
  margin-bottom: 1rem;
}
.au-tab {
  background: transparent;
  border: none;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  padding: 0.5rem 0.9rem;
  cursor: pointer;
  border-radius: 0;
}
.au-tab:hover {
  color: var(--text);
}
.au-tab--active {
  color: var(--primary);
  box-shadow: inset 0 -2px 0 var(--primary);
}
.au-error {
  color: var(--danger);
  font-family: var(--font-mono);
  font-size: 0.85rem;
}
.au-panels {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 1rem;
  align-content: start;
  overflow-y: auto;
  padding-right: 0.75rem;
}
.au-panel {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.25rem;
}
.au-panel--wide {
  grid-column: 1 / -1;
}
.au-panel-title {
  margin: 0 0 0.75rem;
  font-family: var(--font-mono);
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
}
.au-row {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  padding: 0.3rem 0;
  font-size: 0.88rem;
}
.au-label {
  color: var(--text-muted);
}
.au-value {
  font-family: var(--font-mono);
  white-space: nowrap;
}
.au-bar {
  height: 6px;
  border-radius: 3px;
  background: rgba(var(--primary-rgb), 0.15);
  overflow: hidden;
  margin: 0.35rem 0 0.5rem;
}
.au-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 3px;
  transition: width 0.3s;
}
.au-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
}
.au-table th {
  text-align: left;
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  color: var(--text-muted);
  font-weight: 500;
  padding: 0.3rem 0.5rem;
  border-bottom: 1px solid var(--border);
}
.au-table td {
  padding: 0.35rem 0.5rem;
  border-bottom: 1px solid var(--border);
}
.au-num {
  font-family: var(--font-mono);
  white-space: nowrap;
}
/* Outranks the `.au-table th` left alignment so numeric headers sit over
   their right-aligned cells */
.au-table th.au-num,
.au-table td.au-num {
  text-align: right;
}
.au-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.88rem;
  padding: 1.5rem 0;
}
/* Log feed: same terminal voice as the dashboard activity column */
.au-logs {
  flex: 1;
  overflow-y: auto;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  padding-right: 0.75rem;
}
.au-line {
  display: flex;
  gap: 0.75rem;
  padding: 0.25rem 0;
  border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  align-items: baseline;
}
.au-stamp {
  color: var(--text-muted);
  flex-shrink: 0;
}
.au-method {
  color: var(--primary);
  width: 4.5ch;
  flex-shrink: 0;
}
.au-path {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.au-status {
  flex-shrink: 0;
}
.au-status--ok {
  color: var(--success);
}
.au-status--4xx {
  color: var(--warning);
}
.au-status--5xx {
  color: var(--danger);
}
.au-dur {
  color: var(--text-muted);
  flex-shrink: 0;
  min-width: 6ch;
  text-align: right;
}
.au-ip {
  color: var(--text-muted);
  flex-shrink: 0;
}
.au-line--error .au-level {
  color: var(--danger);
  flex-shrink: 0;
}
.au-msg {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
