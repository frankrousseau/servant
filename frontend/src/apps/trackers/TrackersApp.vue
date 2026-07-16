<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import type { AppContext, Entry } from '../types'
import {
  todayInUserTz,
  utcToZonedParts,
  zonedToUtcISO
} from '../../lib/datetime'
import ComboBox from '../../components/ComboBox.vue'
import TrackerCard from './TrackerCard.vue'
import {
  TRACKER_TYPES,
  aggregateByDate,
  logsByDate,
  trackerFromEntry,
  weekMonday,
  type Tracker
} from './trackers'
import { addDays } from '../calendar/recurrence'

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const trackerEntries = ref<Entry[]>([])
const logEntries = ref<Entry[]>([])
const entryMaps = ref<Map<string, Map<string, number>>>(new Map())
const loadState = ref<'loading' | 'ready' | 'error'>('loading')

// ----- heatmap window: as many weeks as the width fits, browsable back -----

// 11px cell + 3px gap; keep in sync with TrackerCard.vue styles.
const CELL = 14
// layout padding + card padding + borders around the heatmap.
const CHROME = 76

const layoutEl = ref<HTMLElement | null>(null)
const weeksVisible = ref(16)
// Last day of the heatmap window; today unless browsing the past.
const windowEnd = ref(todayInUserTz())
let resizeObs: ResizeObserver | null = null

function measureWeeks() {
  const w = layoutEl.value?.clientWidth || 0
  if (w)
    weeksVisible.value = Math.min(
      104,
      Math.max(8, Math.floor((w - CHROME) / CELL))
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

// Day values of entry-based trackers, computed server-side in the user's
// timezone; a failing aggregate (revoked scope, deleted kind) shows empty.
// No `to` bound: the streak/7d stats always need the recent days.
// Window navigation and the ResizeObserver can fire overlapping loads; a stale
// (slower) response must not clobber the current window's data.
let aggregateSeq = 0

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
      .filter(t => t.type === 'entry' && t.entryKind)
      .map(async t => {
        const params: Record<string, string> = { kind: t.entryKind!, from }
        if (t.agg === 'sum' && t.field) {
          params.agg = 'sum'
          params.field = t.field
        }
        try {
          maps.set(
            t.id,
            aggregateByDate(await ctx.api.entries.aggregate(params))
          )
        } catch {
          maps.set(t.id, new Map())
        }
      })
  )
  if (seq === aggregateSeq) entryMaps.value = maps
}

async function reload() {
  try {
    // entries.list pages through everything internally.
    const [trackers, logs] = await Promise.all([
      ctx.api.entries.list({ kind: 'tracker' }),
      ctx.api.entries.list({ kind: 'tracker_log' })
    ])
    await loadAggregates(trackers)
    trackerEntries.value = trackers
    logEntries.value = logs
    loadState.value = 'ready'
  } catch {
    loadState.value = 'error'
  }
}

onMounted(() => {
  measureWeeks()
  if (typeof ResizeObserver !== 'undefined' && layoutEl.value) {
    resizeObs = new ResizeObserver(measureWeeks)
    resizeObs.observe(layoutEl.value)
  }
  void reload()
})
onUnmounted(() => resizeObs?.disconnect())

// Moving or resizing the window changes the dates entry trackers need.
watch([windowEnd, weeksVisible], () => {
  if (loadState.value === 'ready') void loadAggregates(trackerEntries.value)
})

const today = computed(() => todayInUserTz())

const trackers = computed<Tracker[]>(() =>
  trackerEntries.value
    .map(trackerFromEntry)
    .sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
)

const mapsById = computed(() => {
  const m = new Map<string, Map<string, number>>()
  for (const t of trackers.value)
    m.set(
      t.id,
      t.type === 'entry'
        ? entryMaps.value.get(t.id) || new Map()
        : logsByDate(logEntries.value, t.id)
    )
  return m
})

// One log per tracker per day: update the day's entry when it exists,
// create it otherwise.
const inFlight = new Set<string>()

async function setValue(tracker: Tracker, date: string, value: number) {
  // Two quick taps both miss the not-yet-created log and each create one,
  // producing duplicate logs for the same tracker/day. Serialize per (tracker, day).
  const key = `${tracker.id}:${date}`
  if (inFlight.has(key)) return
  inFlight.add(key)
  const existing = logEntries.value.find(
    l =>
      l.data.tracker_id === tracker.id &&
      l.occurred_at &&
      utcToZonedParts(l.occurred_at).date === date
  )
  try {
    if (existing) {
      const updated = await ctx.api.entries.update(existing.id, {
        title: `${tracker.name}: ${value}`,
        data: { ...existing.data, value }
      })
      logEntries.value = logEntries.value.map(l =>
        l.id === updated.id ? updated : l
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
    // the card keeps showing the stored value
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

// Existing kinds (with entry counts) feed the entry-tracker dropdown; the
// trackers' own kinds would be circular and are left out.
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

// Numeric data fields of a recent entry of the chosen kind, for SUM.
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
      .filter(([, v]) => typeof v === 'number')
      .map(([k]) => ({ value: k, label: k }))
    if (fieldOptions.value.length === 1)
      draftField.value = fieldOptions.value[0].value
  } catch {
    // keep the empty list; the create button stays disabled
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
  const logs = logEntries.value.filter(l => l.data.tracker_id === tracker.id)
  const message =
    tracker.type === 'entry'
      ? `Delete "${tracker.name}"? The ${tracker.entryKind} entries it counts are kept.`
      : `Delete "${tracker.name}" and its ${logs.length} log(s)? This cannot be undone.`
  const ok = await ctx.confirm.ask({
    message,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  try {
    for (const l of logs) await ctx.api.entries.delete(l.id)
    await ctx.api.entries.delete(tracker.id)
    trackerEntries.value = trackerEntries.value.filter(e => e.id !== tracker.id)
    logEntries.value = logEntries.value.filter(
      l => l.data.tracker_id !== tracker.id
    )
  } catch {
    void reload()
  }
}
</script>

<template>
  <div ref="layoutEl" class="tk-layout">
    <p v-if="loadState === 'loading'" class="tk-placeholder">
      Loading trackers…
    </p>
    <p v-else-if="loadState === 'error'" class="tk-placeholder">
      Failed to load trackers.
    </p>
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
        <button class="tk-new" @click="openModal">+ Tracker</button>
      </div>

      <p v-if="!trackers.length" class="tk-placeholder">
        Nothing tracked yet. A tracker can be anything: did I play guitar today,
        how many drinks, this morning's weight…
      </p>

      <div class="tk-grid">
        <TrackerCard
          v-for="t in trackers"
          :key="t.id"
          :tracker="t"
          :by-date="mapsById.get(t.id) || new Map()"
          :today="today"
          :weeks="weeksVisible"
          :window-end="windowEnd"
          @set="(date, value) => setValue(t, date, value)"
          @remove="removeTracker(t)"
        />
      </div>
    </template>
  </div>

  <Teleport to="body">
    <div
      v-if="modalOpen"
      class="tk-modal-overlay"
      @click.self="modalOpen = false"
    >
      <div class="tk-modal">
        <div class="tk-modal-header">New tracker</div>
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
    </div>
  </Teleport>
</template>

<style scoped>
.tk-layout {
  padding: 1rem 1.25rem;
  height: calc(100vh - 4rem);
  overflow-y: auto;
}
.tk-placeholder {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
  padding: 1.5rem 0;
}
.tk-toolbar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
}
.tk-date {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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

.tk-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
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
