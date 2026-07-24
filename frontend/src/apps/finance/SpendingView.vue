<script setup lang="ts">
import { computed, ref } from 'vue'
import type { Entry } from '../types'
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

// ponytail: last 12 months only; older data is still in the transactions
// list, revisit with a range picker if a longer horizon matters.
const MAX_MONTHS = 12

const spending = computed(() =>
  monthlySpending(
    props.txs,
    props.rates,
    props.refCurrency,
    sharedTxNames(props.accounts)
  )
)

const months = computed(() => spending.value.months.slice(-MAX_MONTHS))
const capped = computed(() => spending.value.months.length > MAX_MONTHS)

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

// Every category with spending, largest first: the legend shows them all,
// hidden included, so they can be brought back.
const allRows = computed(() =>
  spending.value.rows
    .map(r => ({
      ...r,
      total: months.value.reduce((sum, m) => sum + (r.byMonth[m] || 0), 0)
    }))
    .filter(r => r.total > 0)
    .sort((a, b) => b.total - a.total)
)

// What the chart and table consolidate.
const rows = computed(() =>
  allRows.value.filter(r => !hidden.value.has(r.category))
)

const monthTotal = (month: string) =>
  rows.value.reduce((sum, r) => sum + (r.byMonth[month] || 0), 0)

const fmt = (v: number) => formatAmount(v, props.refCurrency)
const cell = (r: { byMonth: Record<string, number> }, m: string) =>
  r.byMonth[m] ? fmt(r.byMonth[m]) : '-'

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
  const ms = months.value
  if (!ms.length || !rows.value.length) return null
  const maxTotal = Math.max(...ms.map(monthTotal), 1)
  const step = tickStep(maxTotal)
  const top = Math.ceil(maxTotal / step) * step
  const innerW = W - PAD_LEFT - PAD_RIGHT
  const slot = innerW / ms.length
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
  const labels = ms.map((m, i) => ({
    x: PAD_LEFT + i * slot + slot / 2,
    text: m.slice(5)
  }))
  ms.forEach((m, i) => {
    let y = H - PAD_BOTTOM
    for (const r of rows.value) {
      const v = r.byMonth[m] || 0
      if (!v) continue
      const height = v * scale
      y -= height
      segments.push({
        x: PAD_LEFT + i * slot + (slot - barWidth) / 2,
        y,
        width: barWidth,
        height,
        color: categoryColor(r.category),
        title: `${m} ${r.category}: ${fmt(v)}`
      })
    }
  })
  const totals = ms.map((m, i) => ({
    x: PAD_LEFT + i * slot + slot / 2,
    y: H - PAD_BOTTOM - monthTotal(m) * scale - 5,
    text: fmt(monthTotal(m))
  }))
  return { segments, labels, totals, gridlines }
})
</script>

<template>
  <section class="sp">
    <div class="sp-head">
      <h2 class="sp-title">Spending</h2>
      <span v-if="capped" class="sp-note">last {{ MAX_MONTHS }} months</span>
      <span v-if="spending.excludedCount" class="sp-warn">
        {{ spending.excludedCount }} tx without a {{ refCurrency }} rate
        excluded
      </span>
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
      <svg
        v-if="chart"
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
              <th class="sp-cat-col">Category</th>
              <th v-for="m in months" :key="m">{{ m }}</th>
              <th>Total</th>
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
              <td v-for="m in months" :key="m">{{ cell(r, m) }}</td>
              <td class="sp-total">{{ fmt(r.total) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr>
              <td class="sp-cat-col">Total</td>
              <td v-for="m in months" :key="m">{{ fmt(monthTotal(m)) }}</td>
              <td class="sp-total">
                {{ fmt(months.reduce((s, m) => s + monthTotal(m), 0)) }}
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
  align-items: baseline;
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
.sp-note {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--text-muted);
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
