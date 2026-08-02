<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'

import KindIcon from '../components/KindIcon.vue'

import { useAuthStore } from '../stores/auth'
import { useApi } from '../composables/useApi'
import { useSocket, debounce } from '../composables/useSocket'
import type { Entry, ConnectorConfig } from '../types'
import { relativeTime } from '../lib/datetime'
import { kindColor } from '../lib/kind'
import {
  formatDate,
  formatDateTime,
  formatTime,
  todayInUserTz,
  utcToZonedParts
} from '../lib/datetime'
import { getConnectorDef } from '../connectors'
import { occursOn, recurrenceOf } from '../apps/calendar/recurrence'

const api = useApi()
const router = useRouter()
const auth = useAuthStore()

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
        per_page: '30',
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
      // All events, not just future ones: recurring events (birthdays,
      // weekly rituals) have past seed dates but upcoming occurrences.
      // ponytail: per_page 1000, paginate if a calendar ever outgrows it.
      api.get<{ data: Entry[] }>('/api/entries', {
        kind: 'event',
        per_page: '1000'
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

// ----- Today panel -----

interface ChecklistItem {
  text: string
  done: boolean
  due?: string
}

// Today's events, recurring ones included (they occur today when their
// pattern matches, whatever their seed date).
const todaysEvents = computed(() => {
  const today = todayInUserTz()
  return events.value
    .filter(e => {
      if (!e.occurred_at) return false
      const start = utcToZonedParts(e.occurred_at).date
      const rec = recurrenceOf(e.data)
      return rec ? occursOn(start, rec, today) : start === today
    })
    .sort((a, b) =>
      utcToZonedParts(a.occurred_at!).time.localeCompare(
        utcToZonedParts(b.occurred_at!).time
      )
    )
})

// Checklist deadlines compete for the "next" slot once they are less than
// a week out (pending items only, virtual all-day events like the calendar).
const upcomingDeadlines = computed<Entry[]>(() => {
  const d = new Date()
  d.setDate(d.getDate() + 7)
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const horizon = `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, '0')}`
  const out: Entry[] = []
  for (const l of checklists.value) {
    const items = (l.data.items as ChecklistItem[]) || []
    items.forEach((it, i) => {
      if (it.done || !it.due) return
      if (it.due < todayLocal || it.due > horizon) return
      out.push({
        ...l,
        id: `deadline:${l.id}:${i}`,
        kind: 'event',
        title: `⏰ ${it.text}`,
        occurred_at: `${it.due}T12:00:00Z`,
        // Open until the end of its civil day, so it stays "next" all day.
        data: { all_day: true, end_at: `${it.due}T23:59:59Z` }
      } as Entry)
    })
  }
  return out
})

// Next upcoming event on any day: earliest one not yet finished.
const nextEvent = computed(() => {
  const now = new Date().toISOString()
  const upcoming = [...events.value, ...upcomingDeadlines.value]
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

// Time only if the next event is today, weekday + time otherwise; all-day
// items (deadlines) carry no meaningful time.
const nextEventStamp = computed(() => {
  const e = nextEvent.value
  if (!e?.occurred_at) return ''
  const isToday = utcToZonedParts(e.occurred_at).date === todayInUserTz()
  if (e.data.all_day) {
    if (isToday) return 'today'
    return formatDateTime(e.occurred_at, { weekday: 'short', day: 'numeric' })
  }
  return isToday
    ? formatTime(e.occurred_at)
    : formatDateTime(e.occurred_at, {
        weekday: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      })
})

// Only checklists explicitly flagged for the dashboard (per-list toggle).
// Deadlined items surface first (soonest date on top of the 5-item cut).
const pendingItems = computed(() => {
  const out: {
    listId: string
    index: number
    list: string
    text: string
    due?: string
  }[] = []
  for (const l of checklists.value) {
    if (l.data.show_on_dashboard !== true) continue
    const items = (l.data.items as ChecklistItem[]) || []
    items.forEach((it, index) => {
      if (!it.done)
        out.push({
          listId: l.id,
          index,
          list: l.title || 'Untitled',
          text: it.text,
          due: it.due
        })
    })
  }
  return out.sort((a, b) => {
    if (!!a.due !== !!b.due) return a.due ? -1 : 1
    if (a.due && b.due) return a.due.localeCompare(b.due)
    return 0
  })
})

// Local civil date, matching the checklists app's overdue rule.
const todayLocal = (() => {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, '0')}`
})()

function formatDue(due: string): string {
  const [y, m, d] = due.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC'
  })
}

// Clicking a pending item opens its checklist (checking off happens there).
function openChecklist(p: { listId: string }) {
  router.push(`/apps/checklists?selected=${p.listId}`)
}

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
      <!-- Header: greeting + calendar at a glance -->
      <div class="motd">
        <div class="motd-head">
          <img
            v-if="auth.user?.avatar_path"
            :src="auth.user.avatar_path"
            alt=""
            class="motd-avatar"
          />
          Hello {{ auth.user?.display_name || auth.user?.username }}
        </div>
        <div class="motd-line">
          next:
          <template v-if="nextEvent">
            <span class="motd-num">{{ nextEventStamp }}</span>
            {{ nextEvent.title || nextEvent.data.summary }}
          </template>
          <template v-else>nothing scheduled</template>
        </div>
        <div v-if="todaysEvents.length" class="motd-line">
          today:
          <template v-for="(e, i) in todaysEvents" :key="e.id">
            <template v-if="i"> &middot; </template>
            <span class="motd-num">{{ formatTime(e.occurred_at) }}</span>
            {{ e.title || e.data.summary }}
          </template>
        </div>
      </div>

      <div class="dashboard-layout">
        <!-- Main column: Checklists + Coming up + Recent activity -->
        <div class="dashboard-main">
          <section v-if="pendingItems.length" class="dashboard-section">
            <div class="section-header">
              <h2>Checklists</h2>
              <router-link to="/apps/checklists" class="section-link"
                >View all</router-link
              >
            </div>
            <div
              v-for="it in pendingItems.slice(0, 5)"
              :key="it.listId + ':' + it.index"
              class="today-item today-item--clickable"
              :title="`Open ${it.list}`"
              @click="openChecklist(it)"
            >
              <span class="today-box">☐</span>
              <span class="today-item-text">{{ it.text }}</span>
              <span
                v-if="it.due"
                class="today-due"
                :class="{ 'today-due--overdue': it.due < todayLocal }"
                >{{ formatDue(it.due) }}</span
              >
              <span class="today-list-name">{{ it.list }}</span>
            </div>
            <router-link
              v-if="pendingItems.length > 5"
              to="/apps/checklists"
              class="today-more"
            >
              +{{ pendingItems.length - 5 }} more
            </router-link>
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
                v-click-key
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
            <p class="stats-meta">
              <span class="stats-num">{{ entriesToday }}</span> entries today
              <template v-if="lastSyncAt">
                &middot; last sync {{ relativeTime(lastSyncAt) }}
              </template>
            </p>
            <div class="sidebar-stats">
              <div
                class="stat-card stat-card--total"
                @click="goToData()"
                v-click-key
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
                v-click-key
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
                  v-html="getConnectorDef(c.connector_type)?.logo || ''"
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

/* Header: terminal-style calendar summary */
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
  display: flex;
  align-items: center;
  gap: 0.6rem;
  font-family: var(--font-display);
  font-size: 1.35rem;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(var(--primary-rgb), 0.45);
  margin-bottom: 0.35rem;
}

.motd-avatar {
  width: 34px;
  height: 34px;
  border-radius: 50%;
  object-fit: cover;
  border: 1px solid rgba(var(--primary-rgb), 0.5);
  box-shadow: 0 0 8px rgba(var(--primary-rgb), 0.35);
}

.motd-line {
  color: var(--text-muted);
}

.motd-num {
  color: var(--text);
  font-weight: 600;
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

.today-item--clickable {
  cursor: pointer;
  border-radius: 6px;
}
.today-item--clickable:hover {
  background: var(--bg-hover);
}
.today-item--clickable:hover .today-box {
  color: var(--primary);
}

.today-item-text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.today-due {
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 999px;
  padding: 0.05rem 0.5rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  letter-spacing: 0.04em;
  flex-shrink: 0;
  white-space: nowrap;
}
.today-due--overdue {
  color: var(--danger);
  border-color: var(--danger);
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

/* The dashboard owns the viewport: header fixed on top, then two
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

.stats-meta {
  margin: -0.35rem 0 0.75rem;
  font-size: 0.85rem;
  color: var(--text-muted);
}

.stats-num {
  color: var(--text);
  font-weight: 600;
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
  color: var(--primary-contrast);
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
