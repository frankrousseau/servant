<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { useApi } from '../composables/useApi'
import { useSocket, debounce } from '../composables/useSocket'
import type { Entry, ConnectorConfig } from '../types'
import { relativeTime, kindColor } from '../types'
import {
  formatDate,
  formatDateTime,
  formatTime,
  todayInUserTz,
  utcToZonedParts,
  zonedToUtcISO
} from '../lib/datetime'
import { getConnectorDef } from '../connectors'
import KindIcon from '../components/KindIcon.vue'

const api = useApi()
const router = useRouter()

const recentEntries = ref<Entry[]>([])
const stats = ref<Record<string, number>>({})
const totalEntries = ref(0)
const connectors = ref<ConnectorConfig[]>([])
const dailyStats = ref<Record<string, Record<string, number>>>({})
const events = ref<Entry[]>([])
const checklists = ref<Entry[]>([])
const loading = ref(true)

const { onEntryChange, onBulkChange } = useSocket()

// Coalesce refetches: a connector sync can fire many entry events in a burst,
// and each fetchData() is several requests. Debounce so we refresh once.
const refresh = debounce(() => fetchData())
onEntryChange(refresh)
onBulkChange(refresh)

async function fetchData() {
  try {
    const [
      entriesRes,
      statsRes,
      connectorsRes,
      dailyRes,
      eventsRes,
      checklistsRes
    ] = await Promise.all([
      api.get<{ data: Entry[]; meta: { total: number } }>('/api/entries', {
        per_page: '10',
        sort: 'inserted_at'
      }),
      api.get<{ data: Record<string, number>; total: number }>(
        '/api/entries/stats'
      ),
      api.get<{ data: ConnectorConfig[] }>('/api/connectors'),
      api.get<{ data: Record<string, Record<string, number>> }>(
        '/api/entries/stats/daily',
        { days: '30' }
      ),
      // Events from the start of today (user tz) onward; today's list and
      // the "next:" line both derive from this window.
      // ponytail: 100 events ahead is plenty for a personal calendar.
      api.get<{ data: Entry[] }>('/api/entries', {
        kind: 'event',
        per_page: '100',
        from: zonedToUtcISO(todayInUserTz(), '00:00')
      }),
      api.get<{ data: Entry[] }>('/api/entries', {
        kind: 'checklist',
        per_page: '100'
      })
    ])
    recentEntries.value = entriesRes.data
    stats.value = statsRes.data
    totalEntries.value = statsRes.total
    connectors.value = connectorsRes.data
    dailyStats.value = dailyRes.data
    events.value = eventsRes.data
    checklists.value = checklistsRes.data
  } catch {
    // API not available yet
  } finally {
    loading.value = false
  }
}

// ----- MOTD + Today panel -----

interface ChecklistItem {
  text: string
  done: boolean
}

const motdDate = computed(() =>
  formatDate(new Date().toISOString(), {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric'
  })
)

const todaysEvents = computed(() =>
  events.value
    .filter(
      e =>
        e.occurred_at && utcToZonedParts(e.occurred_at).date === todayInUserTz()
    )
    .sort((a, b) =>
      (a.occurred_at as string) < (b.occurred_at as string) ? -1 : 1
    )
)

// Next upcoming event on any day: earliest one not yet finished.
const nextEvent = computed(() => {
  const now = new Date().toISOString()
  const upcoming = events.value
    .filter(
      e =>
        e.occurred_at &&
        ((e.data.end_at as string) || (e.occurred_at as string)) >= now
    )
    .sort((a, b) =>
      (a.occurred_at as string) < (b.occurred_at as string) ? -1 : 1
    )
  return upcoming[0] || null
})

// Time only if the next event is today, weekday + time otherwise.
const nextEventStamp = computed(() => {
  const e = nextEvent.value
  if (!e?.occurred_at) return ''
  return utcToZonedParts(e.occurred_at).date === todayInUserTz()
    ? formatTime(e.occurred_at)
    : formatDateTime(e.occurred_at, {
        weekday: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      })
})

// Only checklists explicitly flagged for the dashboard (per-list toggle).
const pendingItems = computed(() => {
  const out: { list: string; text: string }[] = []
  for (const l of checklists.value) {
    if (l.data.show_on_dashboard !== true) continue
    for (const it of (l.data.items as ChecklistItem[]) || []) {
      if (!it.done) out.push({ list: l.title || 'Untitled', text: it.text })
    }
  }
  return out
})

// Backend daily stats use UTC days; so does this key.
const entriesToday = computed(() => {
  const key = new Date().toISOString().slice(0, 10)
  let n = 0
  for (const kind of Object.keys(dailyStats.value))
    n += dailyStats.value[kind][key] || 0
  return n
})

const lastSyncAt = computed(() => {
  const ts = connectors.value
    .map(c => c.last_synced_at)
    .filter((t): t is string => !!t)
    .sort()
  return ts.length ? ts[ts.length - 1] : null
})

// Timestamp for a log line: time-of-day if today, short date otherwise.
function logStamp(iso: string): string {
  return utcToZonedParts(iso).date === todayInUserTz()
    ? formatTime(iso)
    : formatDate(iso, { month: 'short', day: 'numeric' })
}

// ----- Sparklines (30 UTC days, bars normalized per kind) -----

const SPARK_DAYS = 30

function sparkBars(
  counts: Record<string, number> | undefined
): { x: number; h: number }[] {
  const vals: number[] = []
  for (let i = SPARK_DAYS - 1; i >= 0; i--) {
    const day = new Date(Date.now() - i * 86_400_000).toISOString().slice(0, 10)
    vals.push(counts?.[day] || 0)
  }
  const max = Math.max(...vals, 1)
  return vals.map((v, i) => ({
    x: i * 3,
    h: v === 0 ? 0.75 : Math.max(1.5, (v / max) * 14)
  }))
}

const totalSpark = computed(() => {
  const merged: Record<string, number> = {}
  for (const perDay of Object.values(dailyStats.value)) {
    for (const [day, count] of Object.entries(perDay)) {
      merged[day] = (merged[day] || 0) + count
    }
  }
  return sparkBars(merged)
})

function goToData(kind?: string) {
  if (kind) {
    router.push({ path: '/data', query: { kind } })
  } else {
    router.push('/data')
  }
}

function goToEntry(entry: Entry) {
  router.push({ path: '/data', query: { entry: entry.id.toString() } })
}

onMounted(fetchData)
</script>

<template>
  <div class="view">
    <p v-if="loading" class="loading-text">Loading...</p>

    <template v-else>
      <!-- MOTD: the machine's status, terminal style -->
      <div class="motd">
        <div class="motd-head">
          SERVANT <span class="motd-sep">//</span> {{ motdDate }}
        </div>
        <div class="motd-line">
          <span class="motd-num">{{ entriesToday }}</span> entries today
          &middot; <span class="motd-num">{{ totalEntries }}</span> total
          <template v-if="lastSyncAt">
            &middot; last sync {{ relativeTime(lastSyncAt) }}
          </template>
        </div>
        <div class="motd-line">
          next:
          <template v-if="nextEvent">
            <span class="motd-num">{{ nextEventStamp }}</span>
            {{ nextEvent.title || nextEvent.data.summary }}
          </template>
          <template v-else>nothing scheduled</template>
          &middot;
          <span class="motd-num">{{ pendingItems.length }}</span> checklist
          items pending
        </div>
      </div>

      <div class="dashboard-layout">
        <!-- Main column: Today + Recent activity -->
        <div class="dashboard-main">
          <section class="dashboard-section">
            <div class="section-header">
              <h2>Today</h2>
              <router-link to="/apps/calendar" class="section-link"
                >Calendar</router-link
              >
            </div>
            <div v-if="todaysEvents.length" class="today-events">
              <div v-for="e in todaysEvents" :key="e.id" class="today-event">
                <span class="today-time">{{ formatTime(e.occurred_at) }}</span>
                <span class="today-title">{{ e.title || e.data.summary }}</span>
                <span v-if="e.data.location" class="today-loc">{{
                  e.data.location
                }}</span>
              </div>
            </div>
            <p v-else class="empty">Nothing scheduled today.</p>

            <div v-if="pendingItems.length" class="today-checklist">
              <div class="today-divider">
                <span class="today-divider-label">Checklists</span>
              </div>
              <div
                v-for="(it, i) in pendingItems.slice(0, 5)"
                :key="i"
                class="today-item"
              >
                <span class="today-box">☐</span>
                <span class="today-item-text">{{ it.text }}</span>
                <span class="today-list-name">{{ it.list }}</span>
              </div>
              <router-link
                v-if="pendingItems.length > 5"
                to="/apps/checklists"
                class="today-more"
              >
                +{{ pendingItems.length - 5 }} more
              </router-link>
            </div>
          </section>

          <section class="dashboard-section">
            <div class="section-header">
              <h2>Recent Activity</h2>
              <router-link to="/data" class="section-link"
                >View all</router-link
              >
            </div>
            <div v-if="recentEntries.length" class="activity-feed">
              <div
                v-for="entry in recentEntries"
                :key="entry.id"
                class="activity-item"
                @click="goToEntry(entry)"
                role="button"
                tabindex="0"
              >
                <span class="log-time">{{ logStamp(entry.inserted_at) }}</span>
                <span class="log-kind" :style="{ color: kindColor(entry.kind) }"
                  >[{{ entry.kind }}]</span
                >
                <span class="log-title">{{ entry.title || entry.kind }}</span>
                <span class="log-source">&larr; {{ entry.source }}</span>
              </div>
            </div>
            <p v-else class="empty">
              No entries yet. Set up a connector to start collecting data.
            </p>
          </section>
        </div>

        <!-- Right sidebar: Stats + Connectors -->
        <aside class="dashboard-sidebar">
          <!-- Stats -->
          <section class="sidebar-section">
            <h2>Statistics</h2>
            <div class="sidebar-stats">
              <div
                class="stat-card stat-card--total"
                @click="goToData()"
                role="button"
                tabindex="0"
              >
                <div class="stat-icon-badge stat-icon-badge--total">
                  <span class="stat-icon-text">&Sigma;</span>
                </div>
                <div class="stat-content">
                  <span class="stat-count">{{ totalEntries }}</span>
                  <span class="stat-label">Total entries</span>
                  <svg
                    class="stat-spark"
                    viewBox="0 0 89 14"
                    preserveAspectRatio="none"
                    aria-hidden="true"
                  >
                    <rect
                      v-for="(b, i) in totalSpark"
                      :key="i"
                      :x="b.x"
                      :y="14 - b.h"
                      width="2"
                      :height="b.h"
                    />
                  </svg>
                </div>
              </div>
              <div
                v-for="(count, kind) in stats"
                :key="kind"
                class="stat-card"
                @click="goToData(kind as string)"
                role="button"
                tabindex="0"
              >
                <div class="stat-icon-badge">
                  <KindIcon :kind="kind as string" :size="18" />
                </div>
                <div class="stat-content">
                  <span class="stat-count">{{ count }}</span>
                  <span class="stat-label">{{ kind }}</span>
                  <svg
                    class="stat-spark"
                    viewBox="0 0 89 14"
                    preserveAspectRatio="none"
                    aria-hidden="true"
                  >
                    <rect
                      v-for="(b, i) in sparkBars(dailyStats[kind as string])"
                      :key="i"
                      :x="b.x"
                      :y="14 - b.h"
                      width="2"
                      :height="b.h"
                    />
                  </svg>
                </div>
              </div>
            </div>
          </section>

          <!-- Connectors status -->
          <section v-if="connectors.length" class="sidebar-section">
            <div class="section-header">
              <h2>Connectors</h2>
              <router-link to="/connectors" class="section-link"
                >Manage</router-link
              >
            </div>
            <div class="connector-status-list">
              <div
                v-for="c in connectors"
                :key="c.id"
                class="connector-status-item"
              >
                <span
                  v-if="getConnectorDef(c.connector_type)"
                  class="connector-mini-logo"
                  v-html="getConnectorDef(c.connector_type)!.logo"
                ></span>
                <span
                  class="connector-dot"
                  :class="{ active: c.enabled, error: c.error }"
                ></span>
                <span class="connector-status-name">
                  {{
                    getConnectorDef(c.connector_type)?.name || c.connector_type
                  }}
                </span>
                <span class="connector-status-meta">
                  <template v-if="c.error">Error</template>
                  <template v-else-if="c.last_synced_at">
                    {{ relativeTime(c.last_synced_at) }}
                  </template>
                  <template v-else>Never synced</template>
                </span>
              </div>
            </div>
          </section>
        </aside>
      </div>
    </template>
  </div>
</template>

<style scoped>
.loading-text {
  color: var(--text-muted);
}

/* MOTD */
.motd {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.25rem;
  margin-bottom: 1.5rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.9rem;
  line-height: 1.7;
}

.motd-head {
  font-family: var(--font-display);
  font-size: 1.35rem;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(var(--primary-rgb), 0.45);
  margin-bottom: 0.35rem;
}

.motd-sep {
  color: var(--text-muted);
  text-shadow: none;
}

.motd-line {
  color: var(--text-muted);
}

.motd-num {
  color: var(--text);
  font-weight: 600;
}

/* Today panel */
.today-events {
  display: flex;
  flex-direction: column;
}

.today-event {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
  padding: 0.45rem 0.5rem;
  border-bottom: 1px solid var(--border);
  font-size: 0.95rem;
}

.today-event:last-child {
  border-bottom: none;
}

.today-time {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color: var(--primary);
  flex-shrink: 0;
}

.today-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.today-loc {
  color: var(--text-muted);
  font-size: 0.85rem;
  margin-left: auto;
  flex-shrink: 0;
}

.today-checklist {
  margin-top: 0.75rem;
  display: flex;
  flex-direction: column;
}

.today-divider {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin: 0.25rem 0 0.4rem;
}

.today-divider::after {
  content: '';
  flex: 1;
  border-top: 1px solid var(--border);
}

.today-divider-label {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
}

.today-item {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  padding: 0.3rem 0.5rem;
  font-size: 0.92rem;
}

.today-box {
  color: var(--text-muted);
  flex-shrink: 0;
}

.today-item-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.today-list-name {
  color: var(--text-muted);
  font-size: 0.8rem;
  margin-left: auto;
  flex-shrink: 0;
}

.today-more {
  padding: 0.3rem 0.5rem;
  font-size: 0.85rem;
}

/* The dashboard owns the viewport: MOTD fixed on top, then two
   independently scrolling columns. */
.view {
  height: calc(100vh - 4rem);
  display: flex;
  flex-direction: column;
}

.dashboard-layout {
  display: grid;
  grid-template-columns: 1fr 300px;
  gap: 2rem;
  flex: 1;
  min-height: 0;
}

.dashboard-main {
  min-width: 0;
  overflow-y: auto;
  min-height: 0;
  padding-right: 0.75rem;
}

/* Sidebar */
.dashboard-sidebar {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
  overflow-y: auto;
  min-height: 0;
  padding-right: 0.75rem;
}

@media (max-width: 860px) {
  .view {
    height: auto;
  }
  .dashboard-layout {
    grid-template-columns: 1fr;
  }
  .dashboard-main,
  .dashboard-sidebar {
    overflow-y: visible;
  }
}

.sidebar-section h2 {
  margin: 0 0 0.75rem;
}

/* Stats */
.sidebar-stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.625rem;
}

.stat-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.875rem;
  display: flex;
  align-items: flex-start;
  gap: 0.625rem;
  cursor: pointer;
  transition:
    border-color 0.2s,
    box-shadow 0.2s;
}

.stat-card:hover {
  border-color: var(--primary);
  box-shadow: 0 2px 12px rgba(var(--primary-rgb), 0.1);
}

.stat-card--total {
  grid-column: 1 / -1;
  background: linear-gradient(
    135deg,
    rgba(var(--primary-rgb), 0.12),
    rgba(var(--primary-rgb), 0.04)
  );
  border-color: rgba(var(--primary-rgb), 0.3);
}

.stat-icon-badge {
  flex-shrink: 0;
  width: 36px;
  height: 36px;
  border-radius: 8px;
  background: rgba(var(--primary-rgb), 0.12);
  color: var(--primary);
  display: flex;
  align-items: center;
  justify-content: center;
}

.stat-icon-badge--total {
  background: linear-gradient(135deg, var(--primary), var(--primary-hover));
  color: #fff;
}

.stat-icon-text {
  font-size: 1.1rem;
  font-weight: 700;
  line-height: 1;
}

.stat-content {
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
  min-width: 0;
}

.stat-count {
  font-weight: 700;
  font-size: 1.25rem;
  line-height: 1.2;
  color: var(--text);
}

.stat-label {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: capitalize;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Sections */
.dashboard-section {
  margin-bottom: 2rem;
}

.section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.section-header h2 {
  margin: 0;
}

.section-link {
  font-size: 0.9rem;
}

/* Connector status */
.connector-status-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.connector-status-item {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.6rem 1rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.9rem;
}

.connector-mini-logo {
  width: 22px;
  height: 22px;
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
  background: #000;
}

.connector-mini-logo :deep(svg),
.connector-mini-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

.connector-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--text-muted);
  flex-shrink: 0;
}

.connector-dot.active {
  background: var(--success);
}

.connector-dot.error {
  background: var(--danger);
}

.connector-status-name {
  font-weight: 500;
}

.connector-status-meta {
  color: var(--text-muted);
  margin-left: auto;
  font-size: 0.85rem;
}

/* Activity feed as terminal log lines */
.activity-feed {
  display: flex;
  flex-direction: column;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}

.activity-item {
  display: flex;
  align-items: baseline;
  gap: 0.65rem;
  padding: 0.4rem 0.5rem;
  cursor: pointer;
  transition: background 0.1s;
  border-radius: var(--radius);
}

.activity-item:hover {
  background: var(--bg-hover);
}

.log-time {
  color: var(--text-muted);
  flex-shrink: 0;
  min-width: 3.2em;
}

.log-kind {
  flex-shrink: 0;
}

.log-title {
  color: var(--text);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.log-source {
  color: var(--text-muted);
  margin-left: auto;
  flex-shrink: 0;
  font-size: 0.8rem;
}

/* Sparklines */
.stat-spark {
  width: 100%;
  height: 14px;
  margin-top: 0.35rem;
  fill: rgba(var(--primary-rgb), 0.65);
}

.stat-content {
  flex: 1;
}
</style>
