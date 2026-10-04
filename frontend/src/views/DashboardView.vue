<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { Sigma } from 'lucide-vue-next'

import KindIcon from '../components/KindIcon.vue'

import { listConnectors } from '../api/connectors'
import {
  dailyStats as fetchDailyStats,
  entryStats,
  listEntriesPage
} from '../api/entries'
import {
  addDays,
  occursOn,
  recurrenceOf,
  upcomingOccurrence
} from '../apps/calendar/recurrence'
import { cryptoEnabled, hiddenEntryKinds } from '../apps/registry'
import { debounce, useSocket } from '../composables/useSocket'
import { blockchainConnector, getConnectorDef } from '../connectors'
import {
  formatDate,
  formatDateTime,
  formatDue,
  formatTime,
  relativeTime,
  todayInUserTz,
  todayLocalStr,
  utcToZonedParts,
  zonedToUtcISO
} from '../lib/datetime'
import { kindColor } from '../lib/kind'
import { useAuthStore } from '../stores/auth'
import type { Item as ChecklistItem } from '../apps/checklists/markdown'
import type { ConnectorConfig, Entry } from '../types'

const router = useRouter()
const auth = useAuthStore()

const recentEntries = ref<Entry[]>([])

// Kinds of an opt-in slice that the user set to off (crypto). A configured
// wallet connector continues to sync. As a result, its entries exist, but
// they stay off-screen.
const hiddenKinds = computed(() => hiddenEntryKinds(auth.user?.enabled_apps))

const visibleRecent = computed(() =>
  recentEntries.value.filter(entry => !hiddenKinds.value.includes(entry.kind))
)
const stats = ref<Record<string, number>>({})
const totalEntries = ref(0)
const connectors = ref<ConnectorConfig[]>([])
const dailyStats = ref<Record<string, Record<string, number>>>({})
const events = ref<Entry[]>([])
const checklists = ref<Entry[]>([])
const loading = ref(true)

const { onEntryChange, onBulkChange } = useSocket()

// Coalesce refetches: a connector sync can fire many entry events in a burst,
// and each fetchData() is several requests. Debounce to refresh one time.
const refresh = debounce(fetchData)
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
      listEntriesPage({ per_page: '30', sort: 'inserted_at' }),
      entryStats(),
      listConnectors(),
      fetchDailyStats(30),
      // All events, not only future ones: recurring events (birthdays,
      // weekly rituals) have past seed dates but upcoming occurrences.
      // ponytail: per_page 1000. Paginate if a calendar gets more events.
      listEntriesPage({ kind: 'event', per_page: '1000' }),
      listEntriesPage({ kind: 'checklist', per_page: '100' })
    ])
    recentEntries.value = entriesRes.data
    stats.value = statsRes.data
    totalEntries.value = statsRes.total
    connectors.value = connectorsRes
    dailyStats.value = dailyRes
    events.value = eventsRes.data
    checklists.value = checklistsRes.data
  } catch {
    // The API is not available yet.
  } finally {
    loading.value = false
  }
}

// ----- Today panel -----

// Local civil date, the same as the overdue rule of the checklists app.
const todayLocal = todayLocalStr()

// Today's events, recurring ones included (they occur today when their
// pattern matches, whatever their seed date).
const todaysEvents = computed(() => {
  const today = todayInUserTz()
  return events.value
    .filter(event => {
      if (!event.occurred_at) return false
      const start = utcToZonedParts(event.occurred_at).date
      const recurrence = recurrenceOf(event.data)
      return recurrence ? occursOn(start, recurrence, today) : start === today
    })
    .sort((a, b) =>
      utcToZonedParts(a.occurred_at!).time.localeCompare(
        utcToZonedParts(b.occurred_at!).time
      )
    )
})

// Checklist deadlines compete for the "next" slot when they are less than
// a week away (pending items only, virtual all-day events as in the calendar).
const upcomingDeadlines = computed<Entry[]>(() => {
  const horizon = addDays(todayLocal, 7)
  const out: Entry[] = []
  for (const list of checklists.value) {
    const items = (list.data.items as ChecklistItem[]) || []
    items.forEach((item, index) => {
      if (item.done || !item.due) return
      if (item.due < todayLocal || item.due > horizon) return
      out.push({
        ...list,
        id: `deadline:${list.id}:${index}`,
        kind: 'event',
        title: `⏰ ${item.text}`,
        occurred_at: `${item.due}T12:00:00Z`,
        // Open until the end of its civil day. As a result, it stays "next"
        // all day.
        data: { all_day: true, end_at: `${item.due}T23:59:59Z` }
      } as Entry)
    })
  }
  return out
})

// Next upcoming event on any day: the earliest one that is not complete yet.
// The code projects recurring events to their next occurrence (same
// wall-clock time). As a result, past seeds still compete for the slot.
const nextEvent = computed(() => {
  const now = new Date().toISOString()
  const { date: today, time: nowTime } = utcToZonedParts(now)
  const upcoming = [...events.value, ...upcomingDeadlines.value]
    .map(event => {
      const recurrence = recurrenceOf(event.data)
      if (!recurrence || !event.occurred_at) return event
      const { date, time } = utcToZonedParts(event.occurred_at)
      const occurrence = upcomingOccurrence(
        date,
        recurrence,
        today,
        time,
        nowTime
      )
      // end_at belongs to the seed occurrence. Drop it on the projection.
      return {
        ...event,
        occurred_at: zonedToUtcISO(occurrence, time),
        data: { ...event.data, end_at: undefined }
      }
    })
    .filter(
      event =>
        event.occurred_at &&
        ((event.data.end_at as string) || (event.occurred_at as string)) >= now
    )
    .sort((a, b) =>
      (a.occurred_at as string) < (b.occurred_at as string) ? -1 : 1
    )
  return upcoming[0] || null
})

// Time only if the next event is today, weekday + time if not. All-day
// items (deadlines) carry no meaningful time.
const nextEventStamp = computed(() => {
  const event = nextEvent.value
  if (!event?.occurred_at) return ''
  const isToday = utcToZonedParts(event.occurred_at).date === todayInUserTz()
  if (event.data.all_day) {
    if (isToday) return 'today'
    return formatDateTime(event.occurred_at, {
      weekday: 'short',
      day: 'numeric'
    })
  }
  return isToday
    ? formatTime(event.occurred_at)
    : formatDateTime(event.occurred_at, {
        weekday: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
      })
})

// Only the checklists explicitly flagged for the dashboard (per-list toggle).
// The items with a deadline come first (soonest date on top of the 5-item cut).
const pendingItems = computed(() => {
  const out: {
    listId: string
    index: number
    listTitle: string
    text: string
    due?: string
  }[] = []
  for (const list of checklists.value) {
    if (list.data.show_on_dashboard !== true) continue
    const items = (list.data.items as ChecklistItem[]) || []
    items.forEach((item, index) => {
      if (!item.done)
        out.push({
          listId: list.id,
          index,
          listTitle: list.title || 'Untitled',
          text: item.text,
          due: item.due
        })
    })
  }
  return out.sort((a, b) => {
    if (!!a.due !== !!b.due) return a.due ? -1 : 1
    if (a.due && b.due) return a.due.localeCompare(b.due)
    return 0
  })
})

// A click on a pending item opens its checklist (the user checks it off there).
function openChecklist({ listId }: { listId: string }) {
  router.push(`/apps/checklists?selected=${listId}`)
}

// The daily stats of the backend use UTC days, and so does this key.
const entriesToday = computed(() => {
  const key = new Date().toISOString().slice(0, 10)
  return Object.values(dailyStats.value).reduce(
    (total, perDay) => total + (perDay[key] || 0),
    0
  )
})

const lastSyncAt = computed(() => {
  const stamps = connectors.value
    .map(connector => connector.last_synced_at)
    .filter((stamp): stamp is string => !!stamp)
    .sort()
  return stamps.length ? stamps[stamps.length - 1] : null
})

// Connectors with an error come first (they must get attention), then the most
// recently synced. The connectors that never synced go to the bottom. The
// def comes along with each connector. As a result, the template resolves it
// one time for each connector. Wallet connectors are out while crypto is off
// (Settings > Apps).
const sortedConnectors = computed(() =>
  connectors.value
    .filter(
      connector =>
        cryptoEnabled(auth.user?.enabled_apps) ||
        !blockchainConnector(connector.connector_type)
    )
    .sort((a, b) => {
      if (!!a.error !== !!b.error) return a.error ? -1 : 1
      return (b.last_synced_at ?? '').localeCompare(a.last_synced_at ?? '')
    })
    .map(connector => ({
      ...connector,
      def: getConnectorDef(connector.connector_type)
    }))
)

// Timestamp for a log line: time-of-day if today, short date if not.
function logStamp(iso: string): string {
  return utcToZonedParts(iso).date === todayInUserTz()
    ? formatTime(iso)
    : formatDate(iso, { month: 'short', day: 'numeric' })
}

function goToConnector(connector: ConnectorConfig) {
  router.push(`/connectors/${connector.id}`)
}

// ----- Sparklines (30 UTC days, bars normalized per kind) -----

const SPARK_DAYS = 30

function sparkBars(
  counts: Record<string, number> | undefined
): { x: number; h: number }[] {
  const values: number[] = []
  for (let i = SPARK_DAYS - 1; i >= 0; i--) {
    const day = new Date(Date.now() - i * 86_400_000).toISOString().slice(0, 10)
    values.push(counts?.[day] || 0)
  }
  const max = Math.max(...values, 1)
  return values.map((value, index) => ({
    x: index * 3,
    h: value === 0 ? 0.75 : Math.max(1.5, (value / max) * 14)
  }))
}

const totalSpark = computed(() => {
  const merged: Record<string, number> = {}
  for (const [kind, perDay] of Object.entries(dailyStats.value)) {
    if (hiddenKinds.value.includes(kind)) continue
    for (const [day, count] of Object.entries(perDay)) {
      merged[day] = (merged[day] || 0) + count
    }
  }
  return sparkBars(merged)
})

// One row for each stat card, total first. The bars are precomputed here, so
// that the template does not rebuild each sparkline on unrelated re-renders.
const statCards = computed(() => {
  const hiddenCount = hiddenKinds.value.reduce(
    (sum, kind) => sum + (stats.value[kind] ?? 0),
    0
  )
  return [
    {
      kind: null as string | null,
      count: totalEntries.value - hiddenCount,
      label: 'Total entries',
      bars: totalSpark.value
    },
    ...Object.entries(stats.value)
      .filter(([kind]) => !hiddenKinds.value.includes(kind))
      .map(([kind, count]) => ({
        kind: kind as string | null,
        count,
        label: kind,
        bars: sparkBars(dailyStats.value[kind])
      }))
  ]
})

function goToData(kind?: string) {
  router.push({ path: '/data', query: kind ? { kind } : {} })
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
        <div v-if="todaysEvents.length" class="motd-line">
          today:
          <template v-for="(event, index) in todaysEvents" :key="event.id">
            <template v-if="index"> &middot; </template>
            <span class="motd-num">{{ formatTime(event.occurred_at) }}</span>
            {{ event.title || event.data.summary }}
          </template>
        </div>
        <div class="motd-line">
          next:
          <template v-if="nextEvent">
            <span class="motd-num">{{ nextEventStamp }}</span>
            {{ nextEvent.title || nextEvent.data.summary }}
          </template>
          <template v-else>nothing scheduled</template>
        </div>
      </div>

      <div class="dashboard-layout">
        <!-- Left: Checklists + Connectors (by activation date) -->
        <div class="dashboard-main">
          <section v-if="pendingItems.length" class="dashboard-section">
            <div class="section-header">
              <h2>Checklists</h2>
              <router-link to="/apps/checklists" class="section-link"
                >View all</router-link
              >
            </div>
            <div
              v-for="item in pendingItems.slice(0, 5)"
              :key="item.listId + ':' + item.index"
              class="today-item today-item--clickable"
              :title="`Open ${item.listTitle}`"
              @click="openChecklist(item)"
            >
              <span class="today-box">☐</span>
              <span class="today-item-text">{{ item.text }}</span>
              <span
                v-if="item.due"
                class="today-due"
                :class="{ 'today-due--overdue': item.due < todayLocal }"
                >{{ formatDue(item.due) }}</span
              >
              <span class="today-list-name">{{ item.listTitle }}</span>
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
              <h2>Connectors</h2>
              <router-link to="/connectors" class="section-link"
                >Manage</router-link
              >
            </div>
            <div v-if="sortedConnectors.length" class="connector-status-list">
              <div
                v-for="connector in sortedConnectors"
                :key="connector.id"
                class="connector-status-item connector-status-item--clickable"
                :class="{ 'connector-status-item--error': !!connector.error }"
                @click="goToConnector(connector)"
                v-click-key
                role="button"
                tabindex="0"
              >
                <span
                  v-if="connector.def"
                  class="connector-mini-logo"
                  v-html="connector.def.logo || ''"
                ></span>
                <span
                  class="connector-dot"
                  :class="{ active: connector.enabled, error: connector.error }"
                ></span>
                <span class="connector-status-name">
                  {{
                    connector.name ||
                    connector.def?.name ||
                    connector.connector_type
                  }}
                </span>
                <span
                  v-if="connector.error"
                  class="connector-status-meta connector-status-meta--error"
                  :title="connector.error"
                  >{{ connector.error }}</span
                >
                <span v-else class="connector-status-meta">
                  <template v-if="connector.last_synced_at">
                    {{ relativeTime(connector.last_synced_at) }}
                  </template>
                  <template v-else>Never synced</template>
                </span>
              </div>
            </div>
            <p v-else class="empty">
              No connectors yet.
              <router-link to="/connectors">Set one up</router-link>
              to start collecting data.
            </p>
          </section>
        </div>

        <!-- Middle: Recent activity (fills the leftover width) -->
        <aside class="dashboard-activity">
          <section class="dashboard-section dashboard-section--fill">
            <div class="section-header">
              <h2>Recent Activity</h2>
              <router-link to="/data" class="section-link"
                >View all</router-link
              >
            </div>
            <div v-if="visibleRecent.length" class="activity-feed">
              <div
                v-for="entry in visibleRecent"
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
        </aside>

        <!-- Right: Statistics -->
        <aside class="dashboard-stats">
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
                v-for="card in statCards"
                :key="card.kind ?? 'total'"
                class="stat-card"
                :class="{ 'stat-card--total': !card.kind }"
                @click="goToData(card.kind ?? undefined)"
                v-click-key
                role="button"
                tabindex="0"
              >
                <div
                  class="stat-icon-badge"
                  :class="{ 'stat-icon-badge--total': !card.kind }"
                >
                  <Sigma v-if="!card.kind" :size="18" />
                  <KindIcon v-else :kind="card.kind" :size="18" plain />
                </div>
                <div class="stat-content">
                  <span class="stat-count">{{ card.count }}</span>
                  <span class="stat-label">{{ card.label }}</span>
                  <svg
                    class="stat-spark"
                    viewBox="0 0 89 14"
                    preserveAspectRatio="none"
                    aria-hidden="true"
                  >
                    <rect
                      v-for="(bar, index) in card.bars"
                      :key="index"
                      :x="bar.x"
                      :y="14 - bar.h"
                      width="2"
                      :height="bar.h"
                    />
                  </svg>
                </div>
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

/* ----- Layout: the dashboard owns the viewport, with the header on top, then
   three columns that scroll independently. Full width (overrides the global
   960px cap, which is for narrow settings-style views). ----- */

.view {
  max-width: none;
  height: calc(100vh - 4rem);
  display: flex;
  flex-direction: column;
}

.dashboard-layout {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr) 300px;
  gap: 1.5rem;
  flex: 1;
  min-height: 0;
}

.dashboard-main,
.dashboard-stats {
  min-width: 0;
  overflow-y: auto;
  min-height: 0;
  padding-right: 0.5rem;
}

.dashboard-activity {
  min-width: 0;
  min-height: 0;
  padding-right: 0.5rem;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

/* Two columns: the stats keep their place next to the checklists, and the
   activity feed takes the full width below. The placement is explicit,
   because the DOM order leaves a hole. */
@media (max-width: 1100px) {
  .dashboard-layout {
    grid-template-columns: minmax(0, 1fr) 280px;
  }
  .dashboard-stats {
    grid-column: 2;
    grid-row: 1;
  }
  .dashboard-activity {
    grid-column: 1 / -1;
    grid-row: 2;
  }
}

@media (max-width: 860px) {
  .view {
    height: auto;
  }
  .dashboard-layout {
    grid-template-columns: 1fr;
  }
  .dashboard-main,
  .dashboard-stats,
  .dashboard-activity {
    overflow-y: visible;
  }
  .dashboard-stats,
  .dashboard-activity {
    grid-column: auto;
    grid-row: auto;
  }
}

/* ----- Sections (shared chrome of the three columns) ----- */

.dashboard-section {
  margin-bottom: 2rem;
}

/* The modifier comes after its base, so that its margin-bottom wins the
   cascade. */
.dashboard-section--fill {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  margin-bottom: 0;
}

.dashboard-section--fill .activity-feed {
  flex: 1;
  overflow-y: auto;
  min-height: 0;
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

/* ----- Header: terminal-style calendar summary ----- */

.motd {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.25rem;
  margin-bottom: 1.5rem;
  font-family: var(--font-mono);
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

/* ----- Checklists: pending items ----- */

.today-item {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  padding: 0.3rem 0.5rem;
  font-size: 0.92rem;
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

.today-due {
  border: 1px solid var(--border);
  color: var(--text-muted);
  border-radius: 999px;
  padding: 0.05rem 0.5rem;
  font-family: var(--font-mono);
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

/* ----- Connectors ----- */

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

.connector-status-item--clickable {
  cursor: pointer;
  transition:
    border-color 0.15s,
    background 0.15s;
}
.connector-status-item--clickable:hover {
  border-color: var(--primary);
  background: var(--bg-hover);
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
  flex-shrink: 0;
}

.connector-status-meta {
  color: var(--text-muted);
  margin-left: auto;
  font-size: 0.85rem;
}

/* Connectors with an error: a red-tinted card that shows the message in
   place of the sync time (full text in the tooltip). Keep this after the
   clickable rules, so that the error hover wins the cascade. */
.connector-status-item--error {
  border-color: var(--danger);
  background: color-mix(in srgb, var(--danger) 7%, var(--bg-surface));
}

.connector-status-item--error:hover {
  border-color: var(--danger-hover);
}

.connector-status-meta--error {
  color: var(--danger);
  font-weight: 500;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* ----- Statistics ----- */

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

.stat-content {
  flex: 1;
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

.stat-spark {
  width: 100%;
  height: 14px;
  margin-top: 0.35rem;
  fill: rgba(var(--primary-rgb), 0.65);
}

/* ----- Activity feed as terminal log lines ----- */

.activity-feed {
  display: flex;
  flex-direction: column;
  font-family: var(--font-mono);
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
</style>
