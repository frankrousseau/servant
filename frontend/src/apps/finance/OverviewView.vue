<script setup lang="ts">
import { computed } from 'vue'

import BalanceChart from './BalanceChart.vue'

import { addDays } from '../calendar/recurrence'
import {
  adjustCurve,
  categoryColor,
  cryptoCurve,
  formatAmount,
  freshnessDays,
  freshnessLevel,
  monthlySpending,
  sharedTxNames,
  sumCurves,
  universeCurve,
  valueAt,
  type Account,
  type Rates,
  type SnapshotPoint
} from './finance'
import type { Entry } from '../types'

// The finance landing page: one number, one curve, and what the user must do.
// Everything here is read-only. Management is in the Accounts tab.

const props = defineProps<{
  accounts: Account[]
  seriesByKey: Map<string, SnapshotPoint[]>
  balanceEntries: Entry[]
  txs: Entry[]
  rates: Rates
  refCurrency: string
  today: string
  taxProvision?: number
  cryptoTaxPct?: number
}>()

const emit = defineEmits<{ go: [tab: 'accounts' | 'spending'] }>()

const tradfiCurve = computed(() =>
  universeCurve(
    props.accounts.filter(account => account.universe === 'tradfi'),
    props.seriesByKey,
    props.rates,
    props.refCurrency
  )
)

const cryptoUniverseCurve = computed(() =>
  cryptoCurve(
    props.accounts.filter(account => account.universe === 'crypto'),
    props.seriesByKey,
    props.balanceEntries,
    props.rates,
    props.refCurrency
  )
)

// Tax adjustments (Accounts, Taxes). The tradfi curve has the fixed
// provision as a flat shift (this does not change the 30d delta). The
// configured haircut scales the crypto curve. The defaults change neither.
const tradfiNetPoints = computed(() =>
  adjustCurve(tradfiCurve.value.points, 1, -(props.taxProvision ?? 0))
)

const cryptoNetPoints = computed(() =>
  adjustCurve(
    cryptoUniverseCurve.value.points,
    1 - (props.cryptoTaxPct ?? 0) / 100,
    0
  )
)

const taxAdjusted = computed(
  () => (props.taxProvision ?? 0) !== 0 || (props.cryptoTaxPct ?? 0) !== 0
)

const combined = computed(() => ({
  points: sumCurves([tradfiNetPoints.value, cryptoNetPoints.value]),
  excluded: [
    ...tradfiCurve.value.excluded,
    ...cryptoUniverseCurve.value.excluded
  ]
}))

const total = computed(() => valueAt(combined.value.points, props.today))
const delta30 = computed(
  () => total.value - valueAt(combined.value.points, addDays(props.today, -30))
)

function deltaLabel(delta: number): string {
  const sign = delta > 0 ? '+' : ''
  return `${sign}${formatAmount(delta, props.refCurrency)} / 30d`
}

// Per-universe subtotals, only for universes that hold accounts.
const splits = computed(() =>
  (
    [
      ['tradfi', tradfiNetPoints.value],
      ['crypto', cryptoNetPoints.value]
    ] as const
  )
    .map(([universe, points]) => ({
      universe,
      count: props.accounts.filter(account => account.universe === universe)
        .length,
      total: valueAt(points, props.today)
    }))
    .filter(split => split.count > 0)
)

// ----- this month's spending digest -----

const spending = computed(() =>
  monthlySpending(
    props.txs,
    props.rates,
    props.refCurrency,
    sharedTxNames(props.accounts)
  )
)

const month = computed(() => props.today.slice(0, 7))

const spentThisMonth = computed(() =>
  spending.value.rows.reduce(
    (sum, row) => sum + (row.byMonth[month.value] || 0),
    0
  )
)

const topCategories = computed(() =>
  spending.value.rows
    .map(row => ({
      category: row.category,
      amount: row.byMonth[month.value] || 0
    }))
    .filter(cat => cat.amount > 0)
    .sort((a, b) => b.amount - a.amount)
    .slice(0, 3)
)

// ----- needs attention -----

const staleAccounts = computed(() =>
  props.accounts.filter(
    account =>
      freshnessLevel(
        freshnessDays(props.seriesByKey.get(account.key) || [], props.today)
      ) !== 'ok'
  )
)

interface Alert {
  key: string
  label: string
  detail: string
  tab: 'accounts' | 'spending'
}

const alerts = computed<Alert[]>(() => {
  const out: Alert[] = []
  const stale = staleAccounts.value
  if (stale.length) {
    out.push({
      key: 'stale',
      label: `${stale.length} account(s) with no balance newer than 35 days`,
      detail: stale
        .slice(0, 3)
        .map(account => account.name)
        .join(', '),
      tab: 'accounts'
    })
  }
  if (combined.value.excluded.length) {
    out.push({
      key: 'rates',
      label: `No ${props.refCurrency} rate for: ${combined.value.excluded.join(', ')}`,
      detail:
        'Set it via Accounts, Rates; these accounts are missing from the total.',
      tab: 'accounts'
    })
  }
  if (spending.value.excluded.length) {
    out.push({
      key: 'txrates',
      label: `${spending.value.excluded.length} transaction(s) not counted in spending`,
      detail: `Their currency has no ${props.refCurrency} rate.`,
      tab: 'spending'
    })
  }
  return out
})
</script>

<template>
  <div class="ov">
    <p v-if="!accounts.length" class="ov-empty">
      No accounts yet. Open
      <button class="ov-link" @click="emit('go', 'accounts')">Accounts</button>
      to create one; bank imports appear there by themselves.
    </p>

    <template v-else>
      <section class="ov-hero">
        <span class="ov-caption"
          >all accounts, {{ refCurrency
          }}{{ taxAdjusted ? ', net of taxes' : '' }}</span
        >
        <div class="ov-hero-line">
          <span class="ov-total">{{ formatAmount(total, refCurrency) }}</span>
          <span
            v-if="combined.points.length"
            class="ov-delta"
            :class="{ 'ov-delta--down': delta30 < 0 }"
            title="Change over the last 30 days"
            >{{ deltaLabel(delta30) }}</span
          >
        </div>
        <BalanceChart
          :points="combined.points"
          :end-date="today"
          color="var(--primary)"
        />
        <p v-if="splits.length > 1" class="ov-splits">
          <span v-for="split in splits" :key="split.universe" class="ov-split">
            {{ split.universe }} {{ formatAmount(split.total, refCurrency) }}
          </span>
        </p>
      </section>

      <div class="ov-cards">
        <section class="ov-card">
          <h2 class="ov-card-title">This month</h2>
          <p class="ov-spent">
            <span class="ov-spent-amount">{{
              formatAmount(spentThisMonth, refCurrency)
            }}</span>
            spent
          </p>
          <p v-if="topCategories.length" class="ov-topcats">
            <span
              v-for="cat in topCategories"
              :key="cat.category"
              class="ov-cat"
            >
              <span
                class="ov-cat-dot"
                :style="{ background: categoryColor(cat.category) }"
              ></span>
              {{ cat.category }}
              {{ formatAmount(cat.amount, refCurrency) }}
            </span>
          </p>
          <p v-else class="ov-quiet">No spending recorded this month.</p>
          <button class="ov-link" @click="emit('go', 'spending')">
            All spending →
          </button>
        </section>

        <section class="ov-card">
          <h2 class="ov-card-title">Needs attention</h2>
          <p v-if="!alerts.length" class="ov-quiet">
            Everything fresh: all balances observed within 35 days.
          </p>
          <button
            v-for="alert in alerts"
            :key="alert.key"
            class="ov-alert"
            @click="emit('go', alert.tab)"
          >
            <span class="ov-alert-label">{{ alert.label }}</span>
            <span class="ov-alert-detail">{{ alert.detail }}</span>
          </button>
        </section>
      </div>
    </template>
  </div>
</template>

<style scoped>
.ov-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.88rem;
  padding: 2rem 0;
}
.ov-hero {
  margin-bottom: 1.25rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  background: var(--bg-surface);
}
.ov-caption {
  font-family: var(--font-mono);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}
.ov-hero-line {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
  margin: 0.15rem 0 0.6rem;
}
.ov-total {
  font-family: var(--font-display);
  font-size: 1.9rem;
  font-weight: 500;
}
.ov-delta {
  font-family: var(--font-mono);
  font-size: 0.8rem;
  color: var(--success);
}
.ov-delta--down {
  color: var(--danger);
}
.ov-splits {
  display: flex;
  gap: 1.25rem;
  margin: 0.6rem 0 0;
}
.ov-split {
  font-family: var(--font-mono);
  font-size: 0.78rem;
  color: var(--text-muted);
}
.ov-cards {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.25rem;
}
@media (max-width: 720px) {
  .ov-cards {
    grid-template-columns: 1fr;
  }
}
.ov-card {
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  background: var(--bg-surface);
}
.ov-card-title {
  margin: 0 0 0.6rem;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.05rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.ov-spent {
  margin: 0 0 0.5rem;
  color: var(--text-muted);
}
.ov-spent-amount {
  font-family: var(--font-mono);
  font-size: 1.15rem;
  font-weight: 600;
  color: var(--text);
}
.ov-topcats {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem 1rem;
  margin: 0 0 0.6rem;
}
.ov-cat {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  font-family: var(--font-mono);
  font-size: 0.78rem;
}
.ov-cat-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}
.ov-quiet {
  color: var(--text-muted);
  font-size: 0.85rem;
  margin: 0 0 0.5rem;
}
.ov-link {
  border: none;
  background: transparent;
  color: var(--primary);
  padding: 0;
  font-size: 0.85rem;
  cursor: pointer;
}
.ov-link:hover {
  text-decoration: underline;
}
.ov-alert {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.1rem;
  width: 100%;
  border: none;
  border-top: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  text-align: left;
  padding: 0.5rem 0.25rem;
  cursor: pointer;
  font-size: 0.85rem;
}
.ov-alert:first-of-type {
  border-top: none;
  padding-top: 0;
}
.ov-alert:hover .ov-alert-label {
  color: var(--primary);
}
.ov-alert-label {
  font-weight: 500;
}
.ov-alert-detail {
  color: var(--text-muted);
  font-size: 0.78rem;
}
</style>
