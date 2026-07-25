<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { Entry } from '../types'
import ComboBox from '../../components/ComboBox.vue'
import {
  categoryColor,
  formatAmount,
  monthlySpending,
  sharedTxNames,
  type Account,
  type Rates
} from './finance'

const props = defineProps<{
  txs: Entry[]
  accounts: Account[]
  rates: Rates
  refCurrency: string
}>()

const MAX_MONTHS = 12

const spending = computed(() =>
  monthlySpending(
    props.txs,
    props.rates,
    props.refCurrency,
    sharedTxNames(props.accounts)
  )
)

// ----- range: rolling 12 months, one year, or all years by year -----

const RANGE_LAST12 = 'Last 12 months'
const RANGE_ALL_YEARS = 'All years'

const range = ref(RANGE_LAST12)

const years = computed(() =>
  [...new Set(spending.value.months.map(m => m.slice(0, 4)))].sort().reverse()
)
const rangeOptions = computed(() => [
  RANGE_LAST12,
  ...years.value,
  RANGE_ALL_YEARS
])

// Table columns and chart bars: months, or years when aggregating.
const periods = computed<string[]>(() => {
  if (range.value === RANGE_ALL_YEARS) return [...years.value].reverse()
  if (range.value === RANGE_LAST12)
    return spending.value.months.slice(-MAX_MONTHS)
  return spending.value.months.filter(m => m.startsWith(range.value))
})

const byYears = computed(() => range.value === RANGE_ALL_YEARS)

function rowByPeriod(byMonth: Record<string, number>): Record<string, number> {
  if (!byYears.value) return byMonth
  const out: Record<string, number> = {}
  for (const [m, v] of Object.entries(byMonth)) {
    const y = m.slice(0, 4)
    out[y] = (out[y] || 0) + v
  }
  return out
}

const periodLabel = (p: string) => (byYears.value ? p : p.slice(5))

// ----- chart type: stacked bars over the range, or a pie for one period -----

const CHART_TYPES = ['Bars', 'Pie']
const chartType = ref('Bars')

// The pie reads one period of the current range: a month, or a year when
// the range aggregates by year. Defaults to the most recent.
const piePeriod = ref('')
const piePeriodOptions = computed(() => [...periods.value].reverse())

watch([periods, chartType], () => {
  if (!periods.value.includes(piePeriod.value))
    piePeriod.value = periods.value[periods.value.length - 1] || ''
})

// ----- category visibility (persisted) -----

const STORAGE_KEY = 'servant_finance_hidden_categories'

function loadHidden(): Set<string> {
  try {
    const raw = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]')
    return new Set(
      Array.isArray(raw) ? raw.filter(v => typeof v === 'string') : []
    )
  } catch {
    return new Set()
  }
}

const hidden = ref<Set<string>>(loadHidden())

function persistHidden() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify([...hidden.value]))
}

function toggleCategory(category: string) {
  if (hidden.value.has(category)) hidden.value.delete(category)
  else hidden.value.add(category)
  hidden.value = new Set(hidden.value)
  persistHidden()
}

// Solo on a fresh legend, back to everything when already solo.
function soloCategory(category: string) {
  const others = allRows.value.map(r => r.category).filter(c => c !== category)
  const alreadySolo =
    !hidden.value.has(category) && others.every(c => hidden.value.has(c))
  hidden.value = alreadySolo ? new Set() : new Set(others)
  persistHidden()
}

function showAll() {
  hidden.value = new Set()
  persistHidden()
}

// Table and legend ordering: by cost (default) or alphabetical.
const sortMode = ref<'total' | 'alpha'>('total')

// Every category with spending in range: the legend shows them all,
// hidden included, so they can be brought back.
const allRows = computed(() =>
  spending.value.rows
    .map(r => {
      const byPeriod = rowByPeriod(r.byMonth)
      return {
        category: r.category,
        byPeriod,
        total: periods.value.reduce((sum, p) => sum + (byPeriod[p] || 0), 0)
      }
    })
    .filter(r => r.total > 0)
    .sort((a, b) =>
      sortMode.value === 'alpha'
        ? a.category.localeCompare(b.category)
        : b.total - a.total
    )
)

// What the chart and table consolidate.
const rows = computed(() =>
  allRows.value.filter(r => !hidden.value.has(r.category))
)

const periodTotal = (period: string) =>
  rows.value.reduce((sum, r) => sum + (r.byPeriod[period] || 0), 0)

const fmt = (v: number) => formatAmount(v, props.refCurrency)
const cell = (r: { byPeriod: Record<string, number> }, p: string) =>
  r.byPeriod[p] ? fmt(r.byPeriod[p]) : '-'

// ----- stacked bar chart -----

const W = 1000
const H = 260
const PAD_TOP = 18
const PAD_BOTTOM = 22
const PAD_LEFT = 8
const PAD_RIGHT = 8

interface Segment {
  x: number
  y: number
  width: number
  height: number
  color: string
  title: string
}

// A readable step near max/4: 1, 2, 2.5 or 5 times a power of ten.
function tickStep(max: number): number {
  const raw = max / 4
  const mag = 10 ** Math.floor(Math.log10(raw))
  const candidates = [1, 2, 2.5, 5, 10].map(c => c * mag)
  return candidates.find(c => c >= raw) || candidates[candidates.length - 1]
}

const chart = computed(() => {
  const ps = periods.value
  if (!ps.length || !rows.value.length) return null
  const maxTotal = Math.max(...ps.map(periodTotal), 1)
  const step = tickStep(maxTotal)
  const top = Math.ceil(maxTotal / step) * step
  const innerW = W - PAD_LEFT - PAD_RIGHT
  const slot = innerW / ps.length
  const barWidth = Math.min(slot * 0.66, 72)
  const scale = (H - PAD_TOP - PAD_BOTTOM) / top

  const gridlines = []
  for (let v = step; v <= top; v += step) {
    gridlines.push({
      y: H - PAD_BOTTOM - v * scale,
      label: fmt(v)
    })
  }

  const segments: Segment[] = []
  const labels = ps.map((p, i) => ({
    x: PAD_LEFT + i * slot + slot / 2,
    text: periodLabel(p)
  }))
  ps.forEach((p, i) => {
    let y = H - PAD_BOTTOM
    for (const r of rows.value) {
      const v = r.byPeriod[p] || 0
      if (!v) continue
      const height = v * scale
      y -= height
      segments.push({
        x: PAD_LEFT + i * slot + (slot - barWidth) / 2,
        y,
        width: barWidth,
        height,
        color: categoryColor(r.category),
        title: `${p} ${r.category}: ${fmt(v)}`
      })
    }
  })
  const totals = ps.map((p, i) => ({
    x: PAD_LEFT + i * slot + slot / 2,
    y: H - PAD_BOTTOM - periodTotal(p) * scale - 5,
    text: fmt(periodTotal(p))
  }))
  return { segments, labels, totals, gridlines }
})

// ----- pie geometry -----

const PIE_R = 90
const PIE_R0 = 46
const PIE_CX = 100
const PIE_CY = 100

function polar(r: number, a: number): [number, number] {
  return [PIE_CX + r * Math.cos(a), PIE_CY + r * Math.sin(a)]
}

function slicePath(r0: number, r1: number, a0: number, a1: number): string {
  const large = a1 - a0 > Math.PI ? 1 : 0
  const [x0, y0] = polar(r1, a0)
  const [x1, y1] = polar(r1, a1)
  const [x2, y2] = polar(r0, a1)
  const [x3, y3] = polar(r0, a0)
  return (
    `M ${x0.toFixed(2)} ${y0.toFixed(2)} ` +
    `A ${r1} ${r1} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)} ` +
    `L ${x2.toFixed(2)} ${y2.toFixed(2)} ` +
    `A ${r0} ${r0} 0 ${large} 0 ${x3.toFixed(2)} ${y3.toFixed(2)} Z`
  )
}

const pie = computed(() => {
  const p = piePeriod.value
  if (!p) return null
  const parts = rows.value
    .map(r => ({ category: r.category, value: r.byPeriod[p] || 0 }))
    .filter(x => x.value > 0)
  const total = parts.reduce((sum, x) => sum + x.value, 0)
  if (!total) return null

  let angle = -Math.PI / 2
  const slices = parts.map(x => {
    const sweep = Math.min((x.value / total) * 2 * Math.PI, 2 * Math.PI - 1e-4)
    const d = slicePath(PIE_R0, PIE_R, angle, angle + sweep)
    angle += sweep
    return {
      d,
      color: categoryColor(x.category),
      title: `${x.category}: ${fmt(x.value)}`
    }
  })
  const breakdown = parts.map(x => ({
    category: x.category,
    color: categoryColor(x.category),
    amount: fmt(x.value),
    pct: Math.round((x.value / total) * 100)
  }))
  return { slices, breakdown, total: fmt(total) }
})
</script>

<template>
  <section class="sp">
    <div class="sp-head">
      <h2 class="sp-title">Spending</h2>
      <span v-if="spending.excludedCount" class="sp-warn">
        {{ spending.excludedCount }} tx without a {{ refCurrency }} rate
        excluded
      </span>
      <span class="sp-head-spacer"></span>
      <ComboBox
        v-model="chartType"
        class="sp-chart-type"
        :options="CHART_TYPES"
      />
      <ComboBox
        v-if="chartType === 'Pie'"
        v-model="piePeriod"
        class="sp-range"
        :options="piePeriodOptions"
      />
      <ComboBox v-model="range" class="sp-range" :options="rangeOptions" />
    </div>

    <div v-if="allRows.length" class="sp-legend">
      <button
        v-for="r in allRows"
        :key="r.category"
        class="sp-chip"
        :class="{ 'sp-chip--off': hidden.has(r.category) }"
        :title="`${fmt(r.total)}; click to toggle, double-click to solo`"
        @click="toggleCategory(r.category)"
        @dblclick="soloCategory(r.category)"
      >
        <span
          class="sp-dot"
          :style="{ background: categoryColor(r.category) }"
        ></span>
        {{ r.category }}
      </button>
      <button v-if="hidden.size" class="sp-chip sp-chip--all" @click="showAll">
        show all
      </button>
    </div>

    <p v-if="!allRows.length" class="sp-empty">
      No spending recorded yet. Import bank transactions to see them here.
    </p>
    <p v-else-if="!rows.length" class="sp-empty">
      All categories are hidden; click one above to bring it back.
    </p>

    <template v-else>
      <div v-if="chartType === 'Pie' && pie" class="sp-pie-wrap">
        <svg
          class="sp-pie"
          viewBox="0 0 200 200"
          role="img"
          :aria-label="`Spending by category, ${piePeriod}`"
        >
          <path
            v-for="(s, i) in pie.slices"
            :key="i"
            class="sp-seg"
            :d="s.d"
            :fill="s.color"
          >
            <title>{{ s.title }}</title>
          </path>
          <text class="sp-pie-total" x="100" y="97" text-anchor="middle">
            {{ pie.total }}
          </text>
          <text class="sp-pie-period" x="100" y="112" text-anchor="middle">
            {{ piePeriod }}
          </text>
        </svg>
        <div class="sp-breakdown">
          <div
            v-for="b in pie.breakdown"
            :key="b.category"
            class="sp-breakdown-row"
          >
            <span class="sp-dot" :style="{ background: b.color }"></span>
            <span class="sp-breakdown-cat">{{ b.category }}</span>
            <span class="sp-breakdown-amount">{{ b.amount }}</span>
            <span class="sp-breakdown-pct">{{ b.pct }}%</span>
          </div>
        </div>
      </div>

      <svg
        v-else-if="chart"
        class="sp-chart"
        :viewBox="`0 0 ${W} ${H}`"
        role="img"
        aria-label="Monthly spending by category"
      >
        <g v-for="g in chart.gridlines" :key="g.y">
          <line
            class="sp-grid"
            :x1="PAD_LEFT"
            :x2="W - PAD_RIGHT"
            :y1="g.y"
            :y2="g.y"
          />
          <text class="sp-chart-label" :x="PAD_LEFT" :y="g.y - 3">
            {{ g.label }}
          </text>
        </g>
        <rect
          v-for="(s, i) in chart.segments"
          :key="i"
          class="sp-seg"
          :x="s.x"
          :y="s.y"
          :width="s.width"
          :height="s.height"
          :fill="s.color"
          rx="1.5"
        >
          <title>{{ s.title }}</title>
        </rect>
        <text
          v-for="t in chart.totals"
          :key="'t' + t.x"
          class="sp-chart-label sp-chart-label--total"
          :x="t.x"
          :y="t.y"
          text-anchor="middle"
        >
          {{ t.text }}
        </text>
        <text
          v-for="l in chart.labels"
          :key="'l' + l.x"
          class="sp-chart-label"
          :x="l.x"
          :y="H - 6"
          text-anchor="middle"
        >
          {{ l.text }}
        </text>
      </svg>

      <div class="sp-table-wrap">
        <table class="sp-table">
          <thead>
            <tr>
              <th class="sp-cat-col">
                <button
                  class="sp-sort"
                  :class="{ 'sp-sort--active': sortMode === 'alpha' }"
                  title="Sort categories alphabetically"
                  @click="sortMode = 'alpha'"
                >
                  Category{{ sortMode === 'alpha' ? ' ▲' : '' }}
                </button>
              </th>
              <th v-for="p in periods" :key="p">{{ p }}</th>
              <th>
                <button
                  class="sp-sort"
                  :class="{ 'sp-sort--active': sortMode === 'total' }"
                  title="Sort categories by total cost"
                  @click="sortMode = 'total'"
                >
                  Total{{ sortMode === 'total' ? ' ▼' : '' }}
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.category">
              <td class="sp-cat-col">
                <span
                  class="sp-dot"
                  :style="{ background: categoryColor(r.category) }"
                ></span>
                {{ r.category }}
              </td>
              <td v-for="p in periods" :key="p">{{ cell(r, p) }}</td>
              <td class="sp-total">{{ fmt(r.total) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <td class="sp-cat-col">Total</td>
              <td v-for="p in periods" :key="p">{{ fmt(periodTotal(p)) }}</td>
              <td class="sp-total">
                {{ fmt(periods.reduce((s, p) => s + periodTotal(p), 0)) }}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </template>
  </section>
</template>

<style scoped>
.sp {
  margin-bottom: 2rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  background: var(--bg-surface);
}
.sp-head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 0.5rem;
}
.sp-title {
  margin: 0;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.3rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.sp-head-spacer {
  flex: 1;
}
.sp-range {
  width: 160px;
}
.sp-chart-type {
  width: 100px;
}
.sp-pie-wrap {
  display: flex;
  align-items: center;
  gap: 2.5rem;
  margin: 0.5rem 0 1.25rem;
  flex-wrap: wrap;
}
.sp-pie {
  width: 260px;
  max-width: 100%;
  flex-shrink: 0;
}
.sp-pie-total {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 13px;
  font-weight: 600;
  fill: var(--text);
}
.sp-pie-period {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 9px;
  fill: var(--text-muted);
}
.sp-breakdown {
  min-width: 260px;
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}
.sp-breakdown-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.82rem;
  padding: 0.12rem 0;
}
.sp-breakdown-cat {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sp-breakdown-amount {
  margin-left: auto;
}
.sp-breakdown-pct {
  color: var(--text-muted);
  width: 3em;
  text-align: right;
}
.sp-warn {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--danger);
}
.sp-empty {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
  margin: 0.5rem 0 0;
}
.sp-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  margin: 0.5rem 0 0.9rem;
}
.sp-chip {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  border: 1px solid var(--border);
  border-radius: 999px;
  background: transparent;
  color: var(--text);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  padding: 0.12rem 0.6rem;
  cursor: pointer;
  user-select: none;
}
.sp-chip:hover {
  border-color: var(--primary);
}
.sp-chip--off {
  opacity: 0.45;
  text-decoration: line-through;
}
.sp-chip--all {
  color: var(--text-muted);
  border-style: dashed;
}
.sp-chart {
  display: block;
  width: 100%;
  height: auto;
  margin-bottom: 1rem;
}
.sp-grid {
  stroke: var(--border);
  stroke-width: 1;
  stroke-dasharray: 2 4;
}
.sp-seg {
  stroke: var(--bg-surface);
  stroke-width: 1;
  transition: opacity 0.1s;
}
.sp-seg:hover {
  opacity: 0.8;
}
.sp-chart-label {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 10px;
  fill: var(--text-muted);
}
.sp-chart-label--total {
  fill: var(--text);
}
.sp-table-wrap {
  overflow-x: auto;
}
.sp-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.85rem;
}
.sp-table th,
.sp-table td {
  padding: 0.3rem 0.6rem;
  text-align: right;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  white-space: nowrap;
}
.sp-table th {
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  font-weight: 500;
  border-bottom: 1px solid var(--border);
}
.sp-sort {
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  text-transform: inherit;
  letter-spacing: inherit;
  padding: 0;
  cursor: pointer;
}
.sp-sort:hover,
.sp-sort--active {
  color: var(--primary);
}
.sp-table tbody tr {
  border-bottom: 1px solid var(--border);
}
.sp-cat-col {
  text-align: left !important;
  font-family: inherit !important;
}
.sp-dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  margin-right: 0.35rem;
}
.sp-total {
  font-weight: 600;
}
.sp-table tfoot td {
  border-top: 1px solid var(--border);
  color: var(--text-muted);
}
</style>
