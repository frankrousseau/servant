<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'

import ComboBox from '../../components/ComboBox.vue'
import TrackerCard from './TrackerCard.vue'
import TrackerDetailView from './TrackerDetailView.vue'

import {
  todayInUserTz,
  utcToZonedParts,
  zonedToUtcISO
} from '../../lib/datetime'
import { openDialog } from '../../lib/dialog'
import { addDays } from '../calendar/recurrence'
import {
  TRACKER_TYPES,
  aggregateByDate,
  fillBuckets,
  logsByDate,
  trackerFromEntry,
  weekMonday,
  type RollupPeriod,
  type RollupRow,
  type Tracker
} from './trackers'
import type { AppContext, Entry } from '../types'

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const trackerEntries = ref<Entry[]>([])
const logEntries = ref<Entry[]>([])
const entryMaps = ref<Map<string, Map<string, number>>>(new Map())
const loadState = ref<'loading' | 'ready' | 'error'>('loading')

const today = computed(() => todayInUserTz())
const searchQuery = ref('')
const searchEl = ref<HTMLInputElement | null>(null)

// ----- heatmap window: as many weeks as the width fits, browsable back -----

// 11px cell + 3px gap. Keep in sync with the styles of TrackerCard.vue.
const CELL = 14
// layout padding + card padding + borders around the heatmap.
const CHROME = 76

const layoutEl = ref<HTMLElement | null>(null)
const weeksVisible = ref(16)
// The last day of the heatmap window. It is today, unless the user browses
// the past.
const windowEnd = ref(todayInUserTz())
let resizeObs: ResizeObserver | null = null

function measureWeeks() {
  const width = layoutEl.value?.clientWidth || 0
  if (width)
    weeksVisible.value = Math.min(
      104,
      Math.max(8, Math.floor((width - CHROME) / CELL))
    )
}

const atToday = computed(() => windowEnd.value >= today.value)
const windowStart = computed(() =>
  addDays(weekMonday(windowEnd.value), -7 * (weeksVisible.value - 1))
)

function shiftWindow(dir: 1 | -1) {
  const next = addDays(windowEnd.value, dir * 7 * weeksVisible.value)
  windowEnd.value = next >= today.value ? today.value : next
}

// The day values of entry-based trackers. The server computes them in the
// time zone of the user. An aggregate that fails (revoked scope, deleted
// kind) shows empty. There is no `to` bound: the streak stats and the 7d
// stats always use the recent days.
// The window navigation and the ResizeObserver can fire loads that overlap.
// A stale (slower) response must not overwrite the data of the current
// window.
let aggregateSeq = 0

// COUNT of the tracked kind by default. SUM of the configured field when
// the tracker asks for it. The windowed loads and the detail loads share
// these parameters.
function aggregateParams(tracker: Tracker): Record<string, string> {
  const params: Record<string, string> = { kind: tracker.entryKind! }
  if (tracker.agg === 'sum' && tracker.field) {
    params.agg = 'sum'
    params.field = tracker.field
  }
  return params
}

async function loadAggregates(trackers: Entry[]) {
  const seq = ++aggregateSeq
  const from = zonedToUtcISO(
    addDays(windowEnd.value, -weeksVisible.value * 7),
    '00:00'
  )
  const maps = new Map<string, Map<string, number>>()
  await Promise.all(
    trackers
      .map(trackerFromEntry)
      .filter(tracker => tracker.type === 'entry' && tracker.entryKind)
      .map(async tracker => {
        const params = { ...aggregateParams(tracker), from }
        try {
          maps.set(
            tracker.id,
            aggregateByDate(await ctx.api.entries.aggregate(params))
          )
        } catch {
          maps.set(tracker.id, new Map())
        }
      })
  )
  if (seq === aggregateSeq) entryMaps.value = maps
}

async function reload() {
  try {
    // entries.list pages through all the entries internally.
    const [trackers, logs] = await Promise.all([
      ctx.api.entries.list({ kind: 'tracker' }),
      ctx.api.entries.list({ kind: 'tracker_log' })
    ])
    await loadAggregates(trackers)
    trackerEntries.value = trackers
    logEntries.value = logs
    detailCache.clear()
    loadState.value = 'ready'
  } catch {
    loadState.value = 'error'
  }
}

// ----- detail view: per-tracker aggregates, deep-linked through ?tracker= -----

const selectedTrackerId = ref<string | null>(null)

const selectedTracker = computed<Tracker | null>(() => {
  const entry = trackerEntries.value.find(
    item => item.id === selectedTrackerId.value
  )
  return entry ? trackerFromEntry(entry) : null
})

// Entry trackers have no logs. For the detail view, separate server rollups
// of the full history are necessary (entryMaps is windowed). The three
// periods load at the same time. As a result, the selector switches without
// a spinner.
const detailRollups = ref<Record<RollupPeriod, RollupRow[]> | null>(null)
const detailState = ref<'idle' | 'loading' | 'error'>('idle')
const detailCache = new Map<string, Record<RollupPeriod, RollupRow[]>>()
let detailSeq = 0

function openTracker(id: string, opts: { push?: boolean } = {}) {
  const entry = trackerEntries.value.find(item => item.id === id)
  // A stale deep-link id (deleted tracker) falls back to the grid.
  if (!entry) return
  selectedTrackerId.value = id
  if (opts.push !== false)
    history.pushState(null, '', `/apps/trackers?tracker=${id}`)
  if (trackerFromEntry(entry).type === 'entry') void loadDetailRollups(id)
}

function closeDetail(opts: { push?: boolean } = {}) {
  selectedTrackerId.value = null
  if (opts.push !== false) history.pushState(null, '', '/apps/trackers')
  void nextTick(() => searchEl.value?.focus())
}

function onPopState() {
  const id = new URLSearchParams(window.location.search).get('tracker')
  if (id) openTracker(id, { push: false })
  else closeDetail({ push: false })
}

async function loadDetailRollups(id: string) {
  const cached = detailCache.get(id)
  if (cached) {
    detailRollups.value = cached
    detailState.value = 'idle'
    return
  }
  const entry = trackerEntries.value.find(item => item.id === id)
  if (!entry) return
  const tracker = trackerFromEntry(entry)
  if (tracker.type !== 'entry' || !tracker.entryKind) return

  const seq = ++detailSeq
  detailState.value = 'loading'
  detailRollups.value = null
  const base = aggregateParams(tracker)
  try {
    const [week, month, year] = await Promise.all(
      (['week', 'month', 'year'] as const).map(bucket =>
        ctx.api.entries.aggregate({ ...base, bucket })
      )
    )
    if (seq !== detailSeq) return
    const asRows = (rows: { bucket: string; value: number }[]) =>
      rows.map(row => ({ ...row, days: 1 }))
    const result = {
      week: fillBuckets(asRows(week), 'week', today.value),
      month: fillBuckets(asRows(month), 'month', today.value),
      year: fillBuckets(asRows(year), 'year', today.value)
    }
    detailCache.set(id, result)
    detailRollups.value = result
    detailState.value = 'idle'
  } catch {
    if (seq === detailSeq) detailState.value = 'error'
  }
}

const trackers = computed<Tracker[]>(() => {
  const needle = searchQuery.value.trim().toLowerCase()
  return trackerEntries.value
    .map(trackerFromEntry)
    .filter(tracker => !needle || tracker.name.toLowerCase().includes(needle))
    .sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
})

const mapsById = computed(() => {
  const maps = new Map<string, Map<string, number>>()
  for (const tracker of trackers.value)
    maps.set(
      tracker.id,
      tracker.type === 'entry'
        ? entryMaps.value.get(tracker.id) || new Map()
        : logsByDate(logEntries.value, tracker.id)
    )
  return maps
})

// One log for each tracker and each day: update the entry of the day when
// it exists. If not, create it.
const inFlight = new Set<string>()

async function setValue(tracker: Tracker, date: string, value: number) {
  // Two quick taps do not find the log, because it is not created yet. Each
  // tap then creates one, which gives duplicate logs for the same tracker and
  // day. Serialize for each (tracker, day).
  const key = `${tracker.id}:${date}`
  if (inFlight.has(key)) return
  inFlight.add(key)
  const existing = logEntries.value.find(
    log =>
      log.data.tracker_id === tracker.id &&
      log.occurred_at &&
      utcToZonedParts(log.occurred_at).date === date
  )
  try {
    if (existing) {
      const updated = await ctx.api.entries.update(existing.id, {
        title: `${tracker.name}: ${value}`,
        data: { ...existing.data, value }
      })
      logEntries.value = logEntries.value.map(log =>
        log.id === updated.id ? updated : log
      )
    } else {
      const created = await ctx.api.entries.create({
        kind: 'tracker_log',
        source: 'trackers_app',
        title: `${tracker.name}: ${value}`,
        occurred_at: zonedToUtcISO(date, '12:00'),
        data: { tracker_id: tracker.id, value }
      })
      logEntries.value = [...logEntries.value, created]
    }
  } catch {
    // The card continues to show the stored value.
  } finally {
    inFlight.delete(key)
  }
}

// ----- create / delete -----

const modalOpen = ref(false)
const draftName = ref('')
const draftType = ref('check')
const draftUnit = ref('')
const draftKind = ref('')
const draftAgg = ref('count')
const draftField = ref('')
const kindOptions = ref<{ value: string; label: string }[]>([])
const fieldOptions = ref<{ value: string; label: string }[]>([])
const saving = ref(false)

const AGG_OPTIONS = [
  { value: 'count', label: 'COUNT entries' },
  { value: 'sum', label: 'SUM a numeric field' }
]

function openModal() {
  draftName.value = ''
  draftType.value = 'check'
  draftUnit.value = ''
  draftKind.value = ''
  draftAgg.value = 'count'
  draftField.value = ''
  modalOpen.value = true
  void loadKindOptions()
}

// The existing kinds (with entry counts) supply the entry-tracker dropdown.
// The kinds of the trackers themselves are circular, and the list excludes
// them.
async function loadKindOptions() {
  try {
    const stats = await ctx.api.entries.stats()
    kindOptions.value = Object.entries(stats)
      .filter(([kind]) => kind !== 'tracker' && kind !== 'tracker_log')
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([kind, count]) => ({ value: kind, label: `${kind} (${count})` }))
  } catch {
    kindOptions.value = []
  }
}

// The numeric data fields of a recent entry of the selected kind, for SUM.
watch([draftKind, draftAgg], async ([kind, agg]) => {
  draftField.value = ''
  fieldOptions.value = []
  if (!kind || agg !== 'sum') return
  try {
    const res = await ctx.api.fetch(
      `/api/entries?kind=${encodeURIComponent(kind)}&per_page=1`
    )
    const body = (await res.json()) as { data?: Entry[] }
    const sample = body.data?.[0]?.data || {}
    fieldOptions.value = Object.entries(sample)
      .filter(([, value]) => typeof value === 'number')
      .map(([key]) => ({ value: key, label: key }))
    if (fieldOptions.value.length === 1)
      draftField.value = fieldOptions.value[0].value
  } catch {
    // Keep the empty list. The create button stays disabled.
  }
})

const draftValid = computed(() => {
  if (!draftName.value.trim()) return false
  if (draftType.value !== 'entry') return true
  if (!draftKind.value) return false
  return draftAgg.value === 'count' || !!draftField.value
})

async function createTracker() {
  if (!draftValid.value) return
  saving.value = true
  const data: Record<string, unknown> = {
    type: draftType.value,
    unit: draftUnit.value.trim() || null
  }
  if (draftType.value === 'entry') {
    data.entry_kind = draftKind.value
    data.agg = draftAgg.value
    data.field = draftAgg.value === 'sum' ? draftField.value : null
  }
  try {
    await ctx.api.entries.create({
      kind: 'tracker',
      source: 'trackers_app',
      title: draftName.value.trim(),
      data
    })
    await reload()
    modalOpen.value = false
  } catch {
    // leave the modal open
  } finally {
    saving.value = false
  }
}

async function removeTracker(tracker: Tracker) {
  const logs = logEntries.value.filter(
    log => log.data.tracker_id === tracker.id
  )
  const message =
    tracker.type === 'entry'
      ? `Delete "${tracker.name}"? The ${tracker.entryKind} entries it counts are kept.`
      : `Delete "${tracker.name}" and its ${logs.length} log${logs.length === 1 ? '' : 's'}? This cannot be undone.`
  const ok = await ctx.confirm.ask({
    message,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  try {
    for (const log of logs) await ctx.api.entries.delete(log.id)
    await ctx.api.entries.delete(tracker.id)
    trackerEntries.value = trackerEntries.value.filter(
      entry => entry.id !== tracker.id
    )
    logEntries.value = logEntries.value.filter(
      log => log.data.tracker_id !== tracker.id
    )
  } catch {
    void reload()
  }
}

// ----- lifecycle -----

onMounted(() => {
  measureWeeks()
  if (typeof ResizeObserver !== 'undefined' && layoutEl.value) {
    resizeObs = new ResizeObserver(measureWeeks)
    resizeObs.observe(layoutEl.value)
  }
  window.addEventListener('popstate', onPopState)
  void reload().then(() => {
    const id = new URLSearchParams(window.location.search).get('tracker')
    if (id) openTracker(id, { push: false })
  })
})

onUnmounted(() => {
  resizeObs?.disconnect()
  window.removeEventListener('popstate', onPopState)
})

// A move or a resize of the window changes the dates that are necessary for
// entry trackers.
watch([windowEnd, weeksVisible], () => {
  if (loadState.value === 'ready') void loadAggregates(trackerEntries.value)
})
</script>

<template>
  <div ref="layoutEl" class="tk-layout">
    <p v-if="loadState === 'loading'" class="tk-placeholder">
      Loading trackers…
    </p>
    <p v-else-if="loadState === 'error'" class="tk-placeholder">
      Failed to load trackers.
    </p>
    <TrackerDetailView
      v-else-if="selectedTracker"
      :tracker="selectedTracker"
      :by-date="mapsById.get(selectedTracker.id) || new Map()"
      :today="today"
      :server-rollups="selectedTracker.type === 'entry' ? detailRollups : null"
      :server-state="selectedTracker.type === 'entry' ? detailState : 'idle'"
      @back="closeDetail()"
    />
    <template v-else>
      <div class="tk-toolbar">
        <button
          class="tk-nav"
          title="Older"
          aria-label="Older"
          @click="shiftWindow(-1)"
        >
          &#9664;
        </button>
        <button
          class="tk-nav"
          title="Newer"
          aria-label="Newer"
          :disabled="atToday"
          @click="shiftWindow(1)"
        >
          &#9654;
        </button>
        <span class="tk-date"
          >{{ windowStart }} &rarr; {{ atToday ? today : windowEnd }}</span
        >
        <button v-if="!atToday" class="tk-back" @click="windowEnd = today">
          back to today
        </button>
        <span class="tk-spacer"></span>
        <input
          ref="searchEl"
          v-model="searchQuery"
          class="tk-search"
          type="text"
          placeholder="Find a tracker..."
        />
        <button class="tk-new" @click="openModal">+ Tracker</button>
      </div>

      <p v-if="!trackers.length" class="tk-placeholder">
        {{
          searchQuery
            ? 'No tracker matches.'
            : "Nothing tracked yet. A tracker can be anything: did I play guitar today, how many drinks, this morning's weight…"
        }}
      </p>

      <div class="tk-grid">
        <TrackerCard
          v-for="tracker in trackers"
          :key="tracker.id"
          :tracker="tracker"
          :by-date="mapsById.get(tracker.id) || new Map()"
          :today="today"
          :weeks="weeksVisible"
          :window-end="windowEnd"
          @set="(date, value) => setValue(tracker, date, value)"
          @remove="removeTracker(tracker)"
          @open="openTracker(tracker.id)"
        />
      </div>
    </template>
  </div>

  <Teleport to="body">
    <dialog
      v-if="modalOpen"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="tk-modal-title"
      @click.self="modalOpen = false"
      @cancel="modalOpen = false"
    >
      <div class="tk-modal">
        <div id="tk-modal-title" class="tk-modal-header">New tracker</div>
        <div class="tk-modal-field">
          <label>Name</label>
          <input
            v-model="draftName"
            placeholder="e.g. Guitar, Alcohol, Weight"
            @keydown.enter="createTracker"
          />
        </div>
        <div class="tk-modal-field">
          <label>Nature</label>
          <ComboBox v-model="draftType" :options="TRACKER_TYPES" />
        </div>
        <template v-if="draftType === 'entry'">
          <div class="tk-modal-field">
            <label>Entry kind</label>
            <ComboBox
              v-model="draftKind"
              :options="kindOptions"
              placeholder="pick a kind"
            />
          </div>
          <div class="tk-modal-field">
            <label>Aggregation</label>
            <ComboBox v-model="draftAgg" :options="AGG_OPTIONS" />
          </div>
          <div v-if="draftAgg === 'sum'" class="tk-modal-field">
            <label>Field to sum</label>
            <ComboBox
              v-model="draftField"
              :options="fieldOptions"
              :placeholder="
                draftKind
                  ? 'numeric fields of ' + draftKind
                  : 'pick a kind first'
              "
            />
          </div>
        </template>
        <div v-if="draftType !== 'check'" class="tk-modal-field">
          <label>Unit (optional)</label>
          <input v-model="draftUnit" placeholder="dose, kg, min…" />
        </div>
        <div class="tk-modal-actions">
          <span class="tk-modal-spacer"></span>
          <button class="tk-btn" @click="modalOpen = false">Cancel</button>
          <button
            class="tk-btn tk-btn--primary"
            :disabled="saving || !draftValid"
            @click="createTracker"
          >
            Create
          </button>
        </div>
      </div>
    </dialog>
  </Teleport>
</template>

<style scoped>
.tk-layout {
  padding: 1rem 1.25rem;
  height: 100vh;
  overflow-y: auto;
}
.tk-placeholder {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.88rem;
  padding: 1.5rem 0;
}
.tk-toolbar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
}
.tk-search {
  width: 190px;
  padding: 0.4rem 0.65rem;
  font-size: 0.85rem;
}
.tk-date {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}
.tk-spacer {
  flex: 1;
}
.tk-nav {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  width: 28px;
  height: 28px;
  border-radius: 8px;
  font-size: 0.7rem;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.tk-nav:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.tk-nav:disabled {
  opacity: 0.4;
  cursor: default;
}
.tk-back {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  font-size: 0.75rem;
  text-decoration: underline;
  padding: 0;
}
.tk-back:hover {
  color: var(--text);
}
.tk-new,
.tk-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
  white-space: nowrap;
}
.tk-new:hover,
.tk-btn:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.tk-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.tk-btn--primary:hover:not(:disabled) {
  color: var(--primary-contrast);
  background: var(--primary-hover);
}
.tk-btn:disabled {
  opacity: 0.5;
  cursor: default;
}
.tk-grid {
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
}

.tk-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1.25rem;
  width: 100%;
  max-width: 380px;
}
.tk-modal-header {
  font-weight: 600;
  font-size: 1.05rem;
  margin-bottom: 1rem;
}
.tk-modal-field {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  margin-bottom: 0.75rem;
}
.tk-modal-field label {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.tk-modal-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
.tk-modal-spacer {
  flex: 1;
}
</style>
