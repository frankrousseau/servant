<script setup lang="ts">
import { computed, ref, watch } from 'vue'

import ComboBox from '../../components/ComboBox.vue'

import {
  categoryColor,
  formatAmount,
  monthlySpending,
  sharedTxNames,
  type Account,
  type Rates
} from './finance'
import { preferenceRef } from '../preference'
import type { AppContext, Entry } from '../types'

const props = defineProps<{
  ctx: AppContext
  txs: Entry[]
  accounts: Account[]
  rates: Rates
  refCurrency: string
}>()

const MAX_MONTHS = 12

// ----- bank filter -----

const ALL_BANKS = 'All banks'
const bankFilter = ref(ALL_BANKS)

const txAccountOf = (tx: Entry) => ((tx.data.account as string) || '').trim()

const bankOptions = computed(() => [
  ALL_BANKS,
  ...[...new Set(props.txs.map(txAccountOf))].filter(Boolean).sort()
])

const scopedTxs = computed(() =>
  bankFilter.value === ALL_BANKS
    ? props.txs
    : props.txs.filter(tx => txAccountOf(tx) === bankFilter.value)
)

const spending = computed(() =>
  monthlySpending(
    scopedTxs.value,
    props.rates,
    props.refCurrency,
    sharedTxNames(props.accounts)
  )
)

// ----- range: rolling 3 or 12 months, one year, or all years by year -----

const RANGE_LAST3 = 'Last 3 months'
const RANGE_LAST12 = 'Last 12 months'
const RANGE_ALL_YEARS = 'All years'

const range = ref(RANGE_LAST12)
const excludedOpen = ref(false)

const years = computed(() =>
  [...new Set(spending.value.months.map(month => month.slice(0, 4)))]
    .sort()
    .reverse()
)
const rangeOptions = computed(() => [
  RANGE_LAST3,
  RANGE_LAST12,
  ...years.value,
  RANGE_ALL_YEARS
])

// The table columns and the chart bars: months, or years when the range
// aggregates by year.
const periods = computed<string[]>(() => {
  if (range.value === RANGE_ALL_YEARS) return [...years.value].reverse()
  if (range.value === RANGE_LAST3) return spending.value.months.slice(-3)
  if (range.value === RANGE_LAST12)
    return spending.value.months.slice(-MAX_MONTHS)
  return spending.value.months.filter(month => month.startsWith(range.value))
})

const byYears = computed(() => range.value === RANGE_ALL_YEARS)

function rowByPeriod(byMonth: Record<string, number>): Record<string, number> {
  if (!byYears.value) return byMonth
  const out: Record<string, number> = {}
  for (const [month, value] of Object.entries(byMonth)) {
    const year = month.slice(0, 4)
    out[year] = (out[year] || 0) + value
  }
  return out
}

const periodLabel = (period: string) =>
  byYears.value ? period : period.slice(5)

// ----- chart type: stacked bars over the range, or a pie for one period -----

const CHART_TYPES = ['Bars', 'Pie']
const chartType = ref('Bars')

// The pie reads one period of the current range: a month, or a year when
// the range aggregates by year. The default is the most recent period.
const piePeriod = ref('')
const piePeriodOptions = computed(() => [...periods.value].reverse())

watch([periods, chartType], () => {
  if (!periods.value.includes(piePeriod.value))
    piePeriod.value = periods.value[periods.value.length - 1] || ''
})

// ----- category visibility (persisted) -----

const hiddenList = preferenceRef<string[]>(
  props.ctx,
  'finance.hiddenCategories',
  []
)
const hidden = computed(() => new Set(hiddenList.value))

function toggleCategory(category: string) {
  hiddenList.value = hidden.value.has(category)
    ? hiddenList.value.filter(cat => cat !== category)
    : [...hiddenList.value, category]
}

// Shows only this category on a fresh legend. Shows everything again when
// this category is already solo.
function soloCategory(category: string) {
  const others = allRows.value
    .map(row => row.category)
    .filter(cat => cat !== category)
  const alreadySolo =
    !hidden.value.has(category) && others.every(cat => hidden.value.has(cat))
  hiddenList.value = alreadySolo ? [] : others
}

function showAll() {
  hiddenList.value = []
}

// The order of the table and the legend: by cost (default) or alphabetical.
const sortMode = ref<'total' | 'alpha'>('total')

// Every category with spending in range. The legend shows all of them,
// hidden included, so that the user can show them again.
const allRows = computed(() =>
  spending.value.rows
    .map(row => {
      const byPeriod = rowByPeriod(row.byMonth)
      return {
        category: row.category,
        byPeriod,
        total: periods.value.reduce(
          (sum, period) => sum + (byPeriod[period] || 0),
          0
        )
      }
    })
    .filter(row => row.total > 0)
    .sort((a, b) =>
      sortMode.value === 'alpha'
        ? a.category.localeCompare(b.category)
        : b.total - a.total
    )
)

// The rows that the chart and the table consolidate.
const rows = computed(() =>
  allRows.value.filter(row => !hidden.value.has(row.category))
)

const periodTotal = (period: string) =>
  rows.value.reduce((sum, row) => sum + (row.byPeriod[period] || 0), 0)

// The user reads spending as magnitudes across a grid of periods. Cents add
// width and noise and never change what the user reads, so everything here
// is rounded.
const fmt = (value: number) =>
  formatAmount(value, props.refCurrency, { maxDigits: 0 })
const cell = (row: { byPeriod: Record<string, number> }, period: string) =>
  row.byPeriod[period] ? fmt(row.byPeriod[period]) : '-'

// ----- stacked bar chart -----

const W = 1000
const H = 260
const PAD_TOP = 22
const PAD_BOTTOM = 26
const PAD_LEFT = 8
const PAD_RIGHT = 8
const BAR_RADIUS = 4
// Hairline of panel background between two stacked slices.
const SLICE_GAP = 1

interface Slice {
  category: string
  value: number
  amount: string
  pct: number
  color: string
  y: number
  height: number
}

interface Column {
  period: string
  label: string
  total: number
  totalText: string
  totalY: number
  centerX: number
  hitX: number
  hitWidth: number
  capD: string
  slices: Slice[]
}

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

// Clip for one stack: square at the baseline, rounded at its end.
function barCapPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(BAR_RADIUS, w / 2, h)
  const round = (value: number) => value.toFixed(1)
  return (
    `M ${round(x)} ${round(y + r)} A ${r} ${r} 0 0 1 ${round(x + r)} ${round(y)} ` +
    `H ${round(x + w - r)} A ${r} ${r} 0 0 1 ${round(x + w)} ${round(y + r)} ` +
    `V ${round(y + h)} H ${round(x)} Z`
  )
}

const chart = computed(() => {
  const periodList = periods.value
  if (!periodList.length || !rows.value.length) return null
  const maxTotal = Math.max(...periodList.map(periodTotal), 1)
  const step = tickStep(maxTotal)
  const top = Math.ceil(maxTotal / step) * step
  const innerW = W - PAD_LEFT - PAD_RIGHT
  const slot = innerW / periodList.length
  const barWidth = Math.min(slot * 0.6, 64)
  const scale = (H - PAD_TOP - PAD_BOTTOM) / top
  const baseline = H - PAD_BOTTOM

  const gridlines = []
  for (let tick = step; tick <= top; tick += step) {
    gridlines.push({ y: baseline - tick * scale, label: fmt(tick) })
  }

  const columns: Column[] = periodList.map((period, index) => {
    const total = periodTotal(period)
    const x = PAD_LEFT + index * slot + (slot - barWidth) / 2
    const slices: Slice[] = []
    let y = baseline
    for (const row of rows.value) {
      const value = row.byPeriod[period] || 0
      if (!value) continue
      const height = value * scale
      y -= height
      slices.push({
        category: row.category,
        value,
        amount: fmt(value),
        pct: total ? Math.round((value / total) * 100) : 0,
        color: categoryColor(row.category),
        y,
        // The gap belongs to the slice above, so the stack still sits on
        // the baseline.
        height: Math.max(slices.length ? height - SLICE_GAP : height, 1)
      })
    }
    return {
      period,
      label: periodLabel(period),
      total,
      totalText: fmt(total),
      totalY: baseline - total * scale - 6,
      centerX: PAD_LEFT + index * slot + slot / 2,
      hitX: PAD_LEFT + index * slot,
      hitWidth: slot,
      capD: barCapPath(x, y, barWidth, baseline - y),
      slices
    }
  })

  return { columns, gridlines, baseline }
})

// ----- hover readout -----
// One readout at a time: the column under the pointer, plus the slice when
// the pointer is on one. The chart is role="img" and stays out of the tab
// order. The table below gives the same numbers for keyboard and AT.
const hover = ref<{ period: string; category: string | null } | null>(null)

const READOUT_ROWS = 7

const readout = computed(() => {
  const target = hover.value
  if (!target || !chart.value) return null
  const column = chart.value.columns.find(item => item.period === target.period)
  if (!column?.slices.length) return null
  const ranked = [...column.slices].sort((a, b) => b.value - a.value)
  const rest = ranked.slice(READOUT_ROWS)
  return {
    // Use the full period here, not the short label of the axis. The readout
    // names what it reads in the same words as the range selector.
    period: column.period,
    total: column.totalText,
    rows: ranked.slice(0, READOUT_ROWS),
    restCount: rest.length,
    restAmount: fmt(rest.reduce((sum, slice) => sum + slice.value, 0)),
    category: target.category,
    // Put the readout opposite the column that it reads, so the bar stays
    // visible.
    side: column.centerX > W / 2 ? 'left' : 'right'
  }
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
  const period = piePeriod.value
  if (!period) return null
  const parts = rows.value
    .map(row => ({ category: row.category, value: row.byPeriod[period] || 0 }))
    .filter(part => part.value > 0)
  const total = parts.reduce((sum, part) => sum + part.value, 0)
  if (!total) return null

  let angle = -Math.PI / 2
  const slices = parts.map(part => {
    const sweep = Math.min(
      (part.value / total) * 2 * Math.PI,
      2 * Math.PI - 1e-4
    )
    const path = slicePath(PIE_R0, PIE_R, angle, angle + sweep)
    angle += sweep
    return {
      category: part.category,
      d: path,
      color: categoryColor(part.category)
    }
  })
  const breakdown = parts.map(part => ({
    category: part.category,
    color: categoryColor(part.category),
    amount: fmt(part.value),
    pct: Math.round((part.value / total) * 100)
  }))
  return { slices, breakdown, total: fmt(total) }
})

// A hover on a slice (or on its breakdown row) changes what the donut reads.
const pieHover = ref<string | null>(null)

const pieCenter = computed(() => {
  if (!pie.value) return null
  const part = pie.value.breakdown.find(
    item => item.category === pieHover.value
  )
  return part
    ? { value: part.amount, label: `${part.category} · ${part.pct}%` }
    : { value: pie.value.total, label: piePeriod.value }
})
</script>

<template>
  <section class="sp">
    <div class="sp-head">
      <button
        v-if="spending.excluded.length"
        class="sp-warn"
        :class="{ 'sp-warn--open': excludedOpen }"
        title="Show the excluded transactions"
        @click="excludedOpen = !excludedOpen"
      >
        {{ spending.excluded.length }} tx without a {{ refCurrency }} rate
        excluded
      </button>
      <span class="sp-head-spacer"></span>
      <ComboBox
        v-if="bankOptions.length > 2"
        v-model="bankFilter"
        class="sp-range"
        :options="bankOptions"
      />
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

    <div v-if="excludedOpen && spending.excluded.length" class="sp-excluded">
      <p class="sp-excluded-hint">
        These outgoing transactions are not consolidated: their currency has no
        {{ refCurrency }} rate. Set one via Accounts, Rates.
      </p>
      <div v-for="tx in spending.excluded" :key="tx.id" class="sp-excluded-row">
        <span class="sp-excluded-date">{{
          (tx.occurred_at || '').slice(0, 10)
        }}</span>
        <span class="sp-excluded-label">{{
          (tx.data.description as string) || tx.title || ''
        }}</span>
        <span class="sp-excluded-account">{{
          (tx.data.account as string) || ''
        }}</span>
        <span class="sp-excluded-amount">
          {{
            formatAmount(
              (tx.data.amount as number) || 0,
              (tx.data.currency as string) || ''
            )
          }}
        </span>
      </div>
    </div>

    <div v-if="allRows.length" class="sp-legend">
      <button
        v-for="row in allRows"
        :key="row.category"
        class="sp-chip"
        :class="{ 'sp-chip--off': hidden.has(row.category) }"
        :title="`${fmt(row.total)}; click to toggle, double-click to solo`"
        @click="toggleCategory(row.category)"
        @dblclick="soloCategory(row.category)"
      >
        <span
          class="sp-dot"
          :style="{ background: categoryColor(row.category) }"
        ></span>
        {{ row.category }}
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
          @pointerleave="pieHover = null"
        >
          <path
            v-for="slice in pie.slices"
            :key="slice.category"
            class="sp-slice"
            :class="{
              'sp-slice--dim': pieHover && pieHover !== slice.category
            }"
            :d="slice.d"
            :fill="slice.color"
            @pointerenter="pieHover = slice.category"
          />
          <text class="sp-pie-total" x="100" y="97" text-anchor="middle">
            {{ pieCenter?.value }}
          </text>
          <text class="sp-pie-period" x="100" y="112" text-anchor="middle">
            {{ pieCenter?.label }}
          </text>
        </svg>
        <div class="sp-breakdown" @pointerleave="pieHover = null">
          <div
            v-for="part in pie.breakdown"
            :key="part.category"
            class="sp-breakdown-row"
            :class="{ 'sp-breakdown-row--on': pieHover === part.category }"
            @pointerenter="pieHover = part.category"
          >
            <span class="sp-dot" :style="{ background: part.color }"></span>
            <span class="sp-breakdown-cat">{{ part.category }}</span>
            <span class="sp-breakdown-amount">{{ part.amount }}</span>
            <span class="sp-breakdown-pct">{{ part.pct }}%</span>
          </div>
        </div>
      </div>

      <div v-else-if="chart" class="sp-chart-wrap">
        <svg
          class="sp-chart"
          :viewBox="`0 0 ${W} ${H}`"
          role="img"
          aria-label="Spending by category over the selected range"
          @pointerleave="hover = null"
        >
          <defs>
            <clipPath
              v-for="column in chart.columns"
              :id="`sp-cap-${column.period}`"
              :key="column.period"
            >
              <path :d="column.capD" />
            </clipPath>
          </defs>

          <g v-for="line in chart.gridlines" :key="line.y">
            <line
              class="sp-grid"
              :x1="PAD_LEFT"
              :x2="W - PAD_RIGHT"
              :y1="line.y"
              :y2="line.y"
            />
            <text class="sp-chart-label" :x="PAD_LEFT" :y="line.y - 4">
              {{ line.label }}
            </text>
          </g>
          <line
            class="sp-axis"
            :x1="PAD_LEFT"
            :x2="W - PAD_RIGHT"
            :y1="chart.baseline"
            :y2="chart.baseline"
          />

          <!-- Catches the space around a stack, so the whole column reads. -->
          <rect
            v-for="column in chart.columns"
            :key="'hit' + column.period"
            class="sp-hit"
            :x="column.hitX"
            :width="column.hitWidth"
            :y="PAD_TOP"
            :height="chart.baseline - PAD_TOP"
            @pointerenter="hover = { period: column.period, category: null }"
          />

          <g
            v-for="column in chart.columns"
            :key="column.period"
            class="sp-col"
            :class="{
              'sp-col--dim': !!hover && hover.period !== column.period
            }"
          >
            <g :clip-path="`url(#sp-cap-${column.period})`">
              <rect
                v-for="slice in column.slices"
                :key="slice.category"
                class="sp-slice"
                :class="{
                  'sp-slice--dim':
                    hover?.period === column.period &&
                    !!hover.category &&
                    hover.category !== slice.category
                }"
                :x="column.hitX"
                :width="column.hitWidth"
                :y="slice.y"
                :height="slice.height"
                :fill="slice.color"
                @pointerenter="
                  hover = { period: column.period, category: slice.category }
                "
              />
            </g>
            <text
              class="sp-chart-label sp-chart-label--total"
              :class="{
                'sp-chart-label--live': hover?.period === column.period
              }"
              :x="column.centerX"
              :y="column.totalY"
              text-anchor="middle"
            >
              {{ column.totalText }}
            </text>
            <text
              class="sp-chart-label"
              :x="column.centerX"
              :y="H - 8"
              text-anchor="middle"
            >
              {{ column.label }}
            </text>
          </g>
        </svg>

        <div
          v-if="readout"
          class="sp-readout"
          :class="`sp-readout--${readout.side}`"
        >
          <div class="sp-readout-head">
            <span class="sp-readout-period">{{ readout.period }}</span>
            <span class="sp-readout-total">{{ readout.total }}</span>
          </div>
          <div
            v-for="row in readout.rows"
            :key="row.category"
            class="sp-readout-row"
            :class="{ 'sp-readout-row--on': readout.category === row.category }"
          >
            <span class="sp-readout-rail" :style="{ background: row.color }" />
            <span class="sp-readout-cat">{{ row.category }}</span>
            <span class="sp-readout-amount">{{ row.amount }}</span>
            <span class="sp-readout-pct">{{ row.pct }}%</span>
          </div>
          <div v-if="readout.restCount" class="sp-readout-row sp-readout-rest">
            <span class="sp-readout-rail" />
            <span class="sp-readout-cat"
              >{{ readout.restCount }} more categories</span
            >
            <span class="sp-readout-amount">{{ readout.restAmount }}</span>
            <span class="sp-readout-pct"></span>
          </div>
        </div>
      </div>

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
              <th v-for="period in periods" :key="period">{{ period }}</th>
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
            <tr v-for="row in rows" :key="row.category">
              <td class="sp-cat-col">
                <span
                  class="sp-dot"
                  :style="{ background: categoryColor(row.category) }"
                ></span>
                {{ row.category }}
              </td>
              <td v-for="period in periods" :key="period">
                {{ cell(row, period) }}
              </td>
              <td class="sp-total">{{ fmt(row.total) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <td class="sp-cat-col">Total</td>
              <td v-for="period in periods" :key="period">
                {{ fmt(periodTotal(period)) }}
              </td>
              <td class="sp-total">
                {{
                  fmt(
                    periods.reduce(
                      (sum, period) => sum + periodTotal(period),
                      0
                    )
                  )
                }}
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
/* The donut slices and the stacked-bar slices share this. The slices that
   the user does not read become dim. */
.sp-slice {
  transition: opacity 0.15s ease;
}
.sp-slice--dim {
  opacity: 0.32;
}
.sp-pie-total {
  font-family: var(--font-display);
  font-size: 15px;
  fill: var(--text);
}
.sp-pie-period {
  font-family: var(--font-mono);
  font-size: 9px;
  letter-spacing: 0.06em;
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
  font-family: var(--font-mono);
  font-size: 0.82rem;
  padding: 0.12rem 0.4rem;
  border-radius: 6px;
  color: var(--text-muted);
  cursor: default;
}
/* On a hover anywhere (row or slice), the pair lights up together. */
.sp-breakdown-row--on {
  background: var(--bg-hover);
  color: var(--text);
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
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--danger);
  background: transparent;
  border: none;
  padding: 0;
  cursor: pointer;
}
.sp-warn--open,
.sp-warn:hover {
  text-decoration: underline;
}
.sp-excluded {
  border: 1px dashed var(--border);
  border-radius: 8px;
  padding: 0.6rem 0.8rem;
  margin-bottom: 1rem;
  max-height: 260px;
  overflow-y: auto;
}
.sp-excluded-hint {
  color: var(--text-muted);
  font-size: 0.78rem;
  margin: 0 0 0.5rem;
}
.sp-excluded-row {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  font-size: 0.83rem;
  padding: 0.12rem 0;
}
.sp-excluded-date {
  font-family: var(--font-mono);
  font-size: 0.76rem;
  color: var(--text-muted);
  flex-shrink: 0;
}
.sp-excluded-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sp-excluded-account {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  flex-shrink: 0;
}
.sp-excluded-amount {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 0.82rem;
  flex-shrink: 0;
}
.sp-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
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
  font-family: var(--font-mono);
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
.sp-chart-wrap {
  position: relative;
  margin-bottom: 1rem;
}
.sp-chart {
  display: block;
  width: 100%;
  height: auto;
}
.sp-grid {
  stroke: var(--border);
  stroke-width: 1;
  stroke-dasharray: 2 5;
  opacity: 0.7;
}
.sp-axis {
  stroke: var(--border);
  stroke-width: 1;
}
.sp-hit {
  fill: transparent;
  pointer-events: all;
}
/* When the user reads one column, the others become dim. The stack under
   the pointer is the only lit channel, and the rest stays as context. */
.sp-col {
  transition: opacity 0.15s ease;
}
.sp-col--dim {
  opacity: 0.22;
}
.sp-chart-label {
  font-family: var(--font-mono);
  font-size: 10px;
  fill: var(--text-muted);
}
.sp-chart-label--total {
  font-size: 11px;
  fill: var(--text);
}
.sp-chart-label--live {
  fill: var(--primary);
  font-weight: 600;
}

/* ----- Hover readout ----- */

.sp-readout {
  position: absolute;
  top: 0;
  width: 15rem;
  max-width: 45%;
  padding: 0.6rem 0.7rem 0.5rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--bg);
  box-shadow: 0 6px 18px rgba(0, 0, 0, 0.22);
  pointer-events: none;
}
.sp-readout--left {
  left: 0;
}
.sp-readout--right {
  right: 0;
}
.sp-readout-head {
  display: flex;
  align-items: baseline;
  gap: 0.5rem;
  padding-bottom: 0.4rem;
  margin-bottom: 0.4rem;
  border-bottom: 1px solid var(--border);
}
.sp-readout-period {
  font-family: var(--font-mono);
  font-size: 0.68rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
}
.sp-readout-total {
  font-family: var(--font-display);
  font-size: 1.1rem;
  margin-left: auto;
}
.sp-readout-row {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  font-family: var(--font-mono);
  font-size: 0.74rem;
  color: var(--text-muted);
  padding: 0.1rem 0;
}
.sp-readout-rail {
  width: 3px;
  height: 0.85em;
  border-radius: 2px;
  flex-shrink: 0;
}
.sp-readout-cat {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sp-readout-amount {
  margin-left: auto;
  flex-shrink: 0;
}
.sp-readout-pct {
  width: 2.6em;
  text-align: right;
  flex-shrink: 0;
  opacity: 0.7;
}
/* The slice that is under the pointer, called out in its column. */
.sp-readout-row--on {
  color: var(--text);
  font-weight: 600;
}
.sp-readout-rest .sp-readout-rail {
  background: var(--border);
}

@media (prefers-reduced-motion: reduce) {
  .sp-col,
  .sp-slice {
    transition: none;
  }
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
  font-family: var(--font-mono);
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
