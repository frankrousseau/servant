<script setup lang="ts">
import { computed } from 'vue'
import type { Entry } from '../types'
import {
  categoryColor,
  formatAmount,
  monthlySpending,
  type Rates
} from './finance'

const props = defineProps<{
  txs: Entry[]
  rates: Rates
  refCurrency: string
}>()

// ponytail: last 12 months only; older data is still in the transactions
// list, revisit with a range picker if a longer horizon matters.
const MAX_MONTHS = 12

const spending = computed(() =>
  monthlySpending(props.txs, props.rates, props.refCurrency)
)

const months = computed(() => spending.value.months.slice(-MAX_MONTHS))
const capped = computed(() => spending.value.months.length > MAX_MONTHS)

// Rows re-totaled over the visible months, largest first.
const rows = computed(() =>
  spending.value.rows
    .map(r => ({
      ...r,
      total: months.value.reduce((sum, m) => sum + (r.byMonth[m] || 0), 0)
    }))
    .filter(r => r.total > 0)
    .sort((a, b) => b.total - a.total)
)

const monthTotal = (month: string) =>
  rows.value.reduce((sum, r) => sum + (r.byMonth[month] || 0), 0)

const fmt = (v: number) => formatAmount(v, props.refCurrency)
const cell = (r: { byMonth: Record<string, number> }, m: string) =>
  r.byMonth[m] ? fmt(r.byMonth[m]) : '-'

// ----- stacked bar chart -----

const W = 600
const H = 180
const PAD_TOP = 16
const PAD_BOTTOM = 16

interface Segment {
  x: number
  y: number
  width: number
  height: number
  color: string
  title: string
}

const chart = computed(() => {
  const ms = months.value
  if (!ms.length) return null
  const maxTotal = Math.max(...ms.map(monthTotal), 1)
  const slot = W / ms.length
  const barWidth = Math.min(slot * 0.6, 48)
  const scale = (H - PAD_TOP - PAD_BOTTOM) / maxTotal

  const segments: Segment[] = []
  const labels = ms.map((m, i) => ({
    x: i * slot + slot / 2,
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
        x: i * slot + (slot - barWidth) / 2,
        y,
        width: barWidth,
        height,
        color: categoryColor(r.category),
        title: `${m} ${r.category}: ${fmt(v)}`
      })
    }
  })
  const totals = ms.map((m, i) => ({
    x: i * slot + slot / 2,
    y: H - PAD_BOTTOM - monthTotal(m) * scale - 4,
    text: fmt(monthTotal(m))
  }))
  return { segments, labels, totals }
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

    <p v-if="!rows.length" class="sp-empty">
      No spending recorded yet. Import bank transactions to see them here.
    </p>

    <template v-else>
      <svg
        v-if="chart"
        class="sp-chart"
        :viewBox="`0 0 ${W} ${H}`"
        role="img"
        aria-label="Monthly spending by category"
      >
        <rect
          v-for="(s, i) in chart.segments"
          :key="i"
          :x="s.x"
          :y="s.y"
          :width="s.width"
          :height="s.height"
          :fill="s.color"
        >
          <title>{{ s.title }}</title>
        </rect>
        <text
          v-for="t in chart.totals"
          :key="'t' + t.x"
          class="sp-chart-label"
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
          :y="H - 4"
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
.sp-chart {
  display: block;
  width: 100%;
  height: auto;
  margin-bottom: 1rem;
}
.sp-chart-label {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 9px;
  fill: var(--text-muted);
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
