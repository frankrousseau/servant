<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import {
  TRACKER_TYPES,
  rollup,
  type RollupPeriod,
  type RollupRow,
  type Tracker
} from './trackers'

const props = defineProps<{
  tracker: Tracker
  byDate: Map<string, number>
  today: string
  // entry trackers only: rollups fetched server-side by the parent
  serverRollups: Record<RollupPeriod, RollupRow[]> | null
  serverState: 'idle' | 'loading' | 'error'
}>()

const emit = defineEmits<{ back: [] }>()

const headingEl = ref<HTMLElement | null>(null)
onMounted(() => headingEl.value?.focus())

// ----- period selection -----

const PERIODS: { id: RollupPeriod; label: string }[] = [
  { id: 'week', label: 'Week' },
  { id: 'month', label: 'Month' },
  { id: 'year', label: 'Year' }
]

const period = ref<RollupPeriod>('week')

const typeLabel = computed(
  () =>
    TRACKER_TYPES.find(option => option.value === props.tracker.type)?.label ||
    props.tracker.type
)

const entrySource = computed(() => {
  const tracker = props.tracker
  if (tracker.type !== 'entry') return ''
  const how = tracker.agg === 'sum' ? `sum of ${tracker.field}` : 'count'
  return `${how} of ${tracker.entryKind} entries`
})

// ----- rows -----

const allRows = computed<RollupRow[]>(() =>
  props.tracker.type === 'entry'
    ? (props.serverRollups?.[period.value] ?? [])
    : rollup(props.byDate, props.tracker.type, period.value, props.today)
)

// The chart shows the recent past; the table below shows everything.
const CHART_BUCKETS: Record<RollupPeriod, number> = {
  week: 26,
  month: 24,
  year: 100
}

const chartRows = computed(() =>
  allRows.value.slice(-CHART_BUCKETS[period.value])
)

const tableRows = computed(() =>
  [...allRows.value].reverse().map(row => ({
    ...row,
    label: tableLabel(row.bucket),
    text: fmtValue(row)
  }))
)

// ----- formatting -----

function fmtNumber(value: number): string {
  return String(Math.round(value * 100) / 100)
}

function fmtValue(row: RollupRow): string {
  const tracker = props.tracker
  if (tracker.type === 'check')
    return `${row.value} day${row.value === 1 ? '' : 's'}`
  const unit = tracker.unit ? ` ${tracker.unit}` : ''
  if (tracker.type === 'value') {
    if (row.days === 0) return '-'
    return `avg ${fmtNumber(row.value)}${unit} (${row.days} log${row.days === 1 ? '' : 's'})`
  }
  return `${fmtNumber(row.value)}${unit}`
}

function tableLabel(bucket: string): string {
  return period.value === 'week' ? `Week of ${bucket}` : bucket
}

// ----- chart geometry -----

const W = 1000
const H = 240
const PAD_TOP = 26
const PAD_BOTTOM = 26
const PAD_LEFT = 8
const PAD_RIGHT = 8

// A readable step near max/4: 1, 2, 2.5 or 5 times a power of ten.
function tickStep(max: number): number {
  const raw = max / 4
  const mag = 10 ** Math.floor(Math.log10(raw))
  const candidates = [1, 2, 2.5, 5, 10].map(factor => factor * mag)
  return (
    candidates.find(candidate => candidate >= raw) ||
    candidates[candidates.length - 1]
  )
}

interface Bar {
  bucket: string
  x: number
  y: number
  width: number
  height: number
  centerX: number
  hitX: number
  hitWidth: number
  empty: boolean
  axisLabel: string
  valueText: string
  title: string
}

const chart = computed(() => {
  const rows = chartRows.value
  if (!rows.length) return null
  const max = Math.max(...rows.map(row => row.value), 1)
  const step = tickStep(max)
  const top = Math.ceil(max / step) * step
  const slot = (W - PAD_LEFT - PAD_RIGHT) / rows.length
  const barWidth = Math.min(slot * 0.7, 48)
  const scale = (H - PAD_TOP - PAD_BOTTOM) / top
  const baseline = H - PAD_BOTTOM
  const inlineValues = slot >= 38
  // Label every bar when there is room, every Nth (anchored on the most
  // recent one) otherwise.
  const labelEvery = Math.max(1, Math.ceil(rows.length / 13))

  const gridlines = []
  for (let tick = step; tick <= top; tick += step)
    gridlines.push({ y: baseline - tick * scale, label: fmtNumber(tick) })

  const bars: Bar[] = rows.map((row, index) => {
    const height = row.value > 0 ? Math.max(row.value * scale, 1) : 0
    return {
      bucket: row.bucket,
      x: PAD_LEFT + index * slot + (slot - barWidth) / 2,
      y: baseline - height,
      width: barWidth,
      height,
      centerX: PAD_LEFT + index * slot + slot / 2,
      hitX: PAD_LEFT + index * slot,
      hitWidth: slot,
      empty: props.tracker.type === 'value' && row.days === 0,
      axisLabel:
        (rows.length - 1 - index) % labelEvery === 0
          ? axisLabel(row.bucket, slot)
          : '',
      valueText: row.value > 0 ? fmtNumber(row.value) : '',
      title: `${tableLabel(row.bucket)}: ${fmtValue(row)}`
    }
  })

  return { bars, gridlines, baseline, inlineValues }
})

function axisLabel(bucket: string, slot: number): string {
  if (period.value === 'year') return bucket
  if (period.value === 'month') return slot >= 60 ? bucket : bucket.slice(5)
  return bucket.slice(5)
}

// One readout at a time; the chart is role="img" and out of the tab
// order, the table below carries the same numbers for keyboard and AT.
const hover = ref<Bar | null>(null)

const readout = computed(() => {
  const bar = hover.value
  return bar ? bar.title : ''
})
</script>

<template>
  <section class="tkd">
    <div class="tkd-head">
      <button
        class="tkd-back"
        aria-label="Back to trackers"
        @click="emit('back')"
      >
        ← Trackers
      </button>
      <span class="tk-swatch" :style="{ background: tracker.color }"></span>
      <h2 ref="headingEl" class="tkd-name" tabindex="-1">{{ tracker.name }}</h2>
      <span class="tkd-meta">
        {{ typeLabel
        }}<template v-if="tracker.unit"> · {{ tracker.unit }}</template>
        <template v-if="entrySource"> · {{ entrySource }}</template>
      </span>
    </div>

    <div class="tkd-periods" role="group" aria-label="Aggregation period">
      <button
        v-for="option in PERIODS"
        :key="option.id"
        class="tkd-period"
        :class="{ 'tkd-period--active': period === option.id }"
        :aria-pressed="period === option.id"
        @click="period = option.id"
      >
        {{ option.label }}
      </button>
    </div>

    <p v-if="serverState === 'loading'" class="tkd-empty">Loading history…</p>
    <p v-else-if="serverState === 'error'" class="tkd-empty">
      Failed to load the history; try reloading.
    </p>
    <p v-else-if="!allRows.length" class="tkd-empty">No data yet.</p>

    <template v-else>
      <svg
        v-if="chart"
        class="tkd-chart"
        :viewBox="`0 0 ${W} ${H}`"
        role="img"
        :aria-label="`${tracker.name} per ${period}`"
        @mouseleave="hover = null"
      >
        <g v-for="line in chart.gridlines" :key="line.y">
          <line
            :x1="PAD_LEFT"
            :x2="W - PAD_RIGHT"
            :y1="line.y"
            :y2="line.y"
            class="tkd-gridline"
          />
          <text
            :x="W - PAD_RIGHT"
            :y="line.y - 4"
            class="tkd-tick"
            text-anchor="end"
          >
            {{ line.label }}
          </text>
        </g>
        <line
          :x1="PAD_LEFT"
          :x2="W - PAD_RIGHT"
          :y1="chart.baseline"
          :y2="chart.baseline"
          class="tkd-baseline"
        />
        <g v-for="bar in chart.bars" :key="bar.bucket">
          <rect
            v-if="!bar.empty && bar.height > 0"
            :x="bar.x"
            :y="bar.y"
            :width="bar.width"
            :height="bar.height"
            rx="3"
            :fill="tracker.color"
          />
          <text
            v-if="chart.inlineValues && bar.valueText"
            :x="bar.centerX"
            :y="bar.y - 6"
            class="tkd-value"
            text-anchor="middle"
          >
            {{ bar.valueText }}
          </text>
          <text
            v-if="bar.axisLabel"
            :x="bar.centerX"
            :y="chart.baseline + 16"
            class="tkd-tick"
            text-anchor="middle"
          >
            {{ bar.axisLabel }}
          </text>
          <rect
            :x="bar.hitX"
            y="0"
            :width="bar.hitWidth"
            :height="chart.baseline"
            fill="transparent"
            @mouseenter="hover = bar"
          >
            <title>{{ bar.title }}</title>
          </rect>
        </g>
      </svg>

      <p class="tkd-readout" aria-hidden="true">{{ readout }}</p>

      <div class="tkd-table-wrap">
        <table class="tkd-table">
          <thead>
            <tr>
              <th scope="col">Period</th>
              <th scope="col">
                {{ tracker.type === 'value' ? 'Average' : 'Total' }}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="row in tableRows" :key="row.bucket">
              <td>{{ row.label }}</td>
              <td class="tkd-num">{{ row.text }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </section>
</template>

<style scoped>
.tkd {
  display: flex;
  flex-direction: column;
  gap: 0.9rem;
}

/* ----- Header ----- */
.tkd-head {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  flex-wrap: wrap;
}
.tkd-back {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
}
.tkd-back:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.tk-swatch {
  width: 10px;
  height: 10px;
  border-radius: 3px;
  flex-shrink: 0;
}
.tkd-name {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 600;
}
.tkd-name:focus {
  outline: none;
}
.tkd-meta {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--text-muted);
}

/* ----- Period selector ----- */
.tkd-periods {
  display: inline-flex;
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
  align-self: flex-start;
}
.tkd-period {
  border: none;
  background: transparent;
  color: var(--text-muted);
  padding: 0.35rem 0.9rem;
  font-size: 0.85rem;
  cursor: pointer;
}
.tkd-period + .tkd-period {
  border-left: 1px solid var(--border);
}
.tkd-period--active {
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.1);
}

/* ----- Chart ----- */
.tkd-chart {
  width: 100%;
  height: auto;
  display: block;
}
.tkd-gridline {
  stroke: var(--border);
  stroke-dasharray: 3 4;
  vector-effect: non-scaling-stroke;
}
.tkd-baseline {
  stroke: var(--border);
  vector-effect: non-scaling-stroke;
}
.tkd-tick {
  font-family: var(--font-mono);
  font-size: 11px;
  fill: var(--text-muted);
}
.tkd-value {
  font-family: var(--font-mono);
  font-size: 11px;
  fill: var(--text);
}
.tkd-readout {
  margin: 0;
  min-height: 1.2em;
  font-family: var(--font-mono);
  font-size: 0.78rem;
  color: var(--text-muted);
}
.tkd-empty {
  color: var(--text-muted);
}

/* ----- Table ----- */
.tkd-table-wrap {
  max-height: 320px;
  overflow-y: auto;
  border: 1px solid var(--border);
  border-radius: 8px;
}
.tkd-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
}
.tkd-table th,
.tkd-table td {
  text-align: left;
  padding: 0.4rem 0.75rem;
  border-bottom: 1px solid var(--border);
}
.tkd-table thead th {
  position: sticky;
  top: 0;
  background: var(--bg-surface);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
}
.tkd-table tbody tr:last-child td {
  border-bottom: none;
}
.tkd-num {
  font-family: var(--font-mono);
}
</style>
