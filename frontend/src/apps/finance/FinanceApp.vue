<script setup lang="ts">
import { ref, computed, reactive, nextTick, onMounted, watch } from 'vue'

import ComboBox from '../../components/ComboBox.vue'
import DateInput from '../../components/DateInput.vue'
import BalanceChart from './BalanceChart.vue'
import OverviewView from './OverviewView.vue'
import SpendingView from './SpendingView.vue'
import TransactionsSection from './TransactionsSection.vue'

import { todayInUserTz, zonedToUtcISO } from '../../lib/datetime'
import { openDialog } from '../../lib/dialog'
import { addDays } from '../calendar/recurrence'
import { fetchCryptoPrices } from './cryptoPrices'
import {
  ACCOUNT_TYPES,
  accountTxName,
  accountTxs,
  buildAccounts,
  cryptoCurve,
  cryptoSpotTotal,
  formatAmount,
  freshnessDays,
  freshnessLevel,
  rateFor,
  snapshotSeries,
  universeCurve,
  valueAt,
  type Account,
  type Rates,
  type SnapshotPoint,
  type Universe
} from './finance'
import type { AppContext, Entry } from '../types'

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const CRYPTO_COLOR = '#6ccec9'

// ----- data -----

type Tab = 'overview' | 'accounts' | 'spending' | 'cryptos'
const tab = ref<Tab>('overview')
const TABS: Array<{ id: Tab; label: string }> = [
  { id: 'overview', label: 'Overview' },
  { id: 'accounts', label: 'Accounts' },
  { id: 'spending', label: 'Spending' },
  { id: 'cryptos', label: 'Cryptos' }
]

const accountEntries = ref<Entry[]>([])
const balanceEntries = ref<Entry[]>([])
const bankTxs = ref<Entry[]>([])
const prefs = ref<Entry | null>(null)
const loadState = ref<'loading' | 'ready' | 'error'>('loading')

async function reload() {
  try {
    // entries.list pages through everything internally.
    const [accounts, balances, txs, prefsList] = await Promise.all([
      ctx.api.entries.list({ kind: 'account' }),
      ctx.api.entries.list({ kind: 'balance' }),
      ctx.api.entries.list({ kind: 'bank_tx' }),
      ctx.api.entries.list({ kind: 'prefs' })
    ])
    accountEntries.value = accounts
    balanceEntries.value = balances
    bankTxs.value = txs
    prefs.value = prefsList.find(entry => entry.title === 'finance') || null
    loadState.value = 'ready'
  } catch {
    loadState.value = 'error'
  }
}

onMounted(reload)

// ----- preferences (reference currency + manual rates) -----

const refCurrency = computed(() =>
  ((prefs.value?.data.reference_currency as string) || 'EUR').toUpperCase()
)
const rates = computed<Rates>(() => (prefs.value?.data.rates as Rates) || {})

async function savePrefs(patch: Record<string, unknown>) {
  const data = { ...(prefs.value?.data || {}), ...patch }
  try {
    prefs.value = prefs.value
      ? await ctx.api.entries.update(prefs.value.id, { data })
      : await ctx.api.entries.create({
          kind: 'prefs',
          source: 'finance_app',
          title: 'finance',
          data
        })
  } catch {
    // keep the previous prefs
  }
}

function onRefCurrencyChange(value: string) {
  void savePrefs({ reference_currency: value })
}

const refCurrencyOptions = computed(() => {
  const set = new Set(['EUR', 'USD', 'GBP', 'CHF'])
  for (const account of accounts.value)
    if (account.universe === 'tradfi') set.add(account.currency)
  set.add(refCurrency.value)
  return [...set].sort()
})

// ----- rates editor -----

const ratesOpen = ref(false)
const ratesDraft = reactive<Record<string, string>>({})

// Includes portfolio snapshot currencies too: a refCurrency change can
// strand a snapshot stored in a currency no account carries, and it still
// needs a rate to become convertible again.
const foreignCurrencies = computed(() => {
  const accountCurrencies = accounts.value.map(account => account.currency)
  const snapshotCurrencies = portfolioSnapshots.value
    .map(snapshot => ((snapshot.data.currency as string) || '').toUpperCase())
    .filter(currency => currency)
  return [...new Set([...accountCurrencies, ...snapshotCurrencies])]
    .filter(currency => currency !== refCurrency.value)
    .sort()
})

function openRates() {
  for (const key of Object.keys(ratesDraft)) delete ratesDraft[key]
  for (const currency of foreignCurrencies.value) {
    ratesDraft[currency] =
      rates.value[currency] != null ? String(rates.value[currency]) : ''
  }
  ratesOpen.value = true
}

async function saveRates() {
  const next: Rates = {}
  for (const [currency, raw] of Object.entries(ratesDraft)) {
    const value = parseFloat(raw.replace(',', '.'))
    if (Number.isFinite(value) && value > 0) next[currency] = value
  }
  await savePrefs({ rates: next })
  ratesOpen.value = false
}

// ----- accounts / curves -----

const accounts = computed(() =>
  buildAccounts(accountEntries.value, bankTxs.value)
)

const seriesByKey = computed(() => {
  const map = new Map<string, SnapshotPoint[]>()
  for (const account of accounts.value) {
    map.set(
      account.key,
      snapshotSeries(account, balanceEntries.value, bankTxs.value)
    )
  }
  return map
})

const today = computed(() => todayInUserTz())

interface UniverseView {
  universe: Universe
  label: string
  color: string
  accounts: Account[]
  points: SnapshotPoint[]
  excluded: string[]
  total: number
  delta30: number
}

function buildUniverse(
  universe: Universe,
  label: string,
  color: string
): UniverseView {
  const list = accounts.value.filter(account => account.universe === universe)
  const { points, excluded } =
    universe === 'crypto'
      ? cryptoCurve(
          list,
          seriesByKey.value,
          balanceEntries.value,
          rates.value,
          refCurrency.value
        )
      : universeCurve(list, seriesByKey.value, rates.value, refCurrency.value)
  const total = valueAt(points, today.value)
  const delta30 = total - valueAt(points, addDays(today.value, -30))
  return {
    universe,
    label,
    color,
    accounts: list,
    points,
    excluded,
    total,
    delta30
  }
}

const universes = computed<UniverseView[]>(() => [
  buildUniverse('tradfi', 'Tradfi', 'var(--primary)'),
  buildUniverse('crypto', 'Crypto', CRYPTO_COLOR)
])

const grandTotal = computed(() =>
  universes.value.reduce((sum, universe) => sum + universe.total, 0)
)
const bothUniversesLive = computed(() =>
  universes.value.every(universe => universe.points.length > 0)
)

// ----- per-account helpers -----

function lastPoint(account: Account): SnapshotPoint | null {
  const series = seriesByKey.value.get(account.key) || []
  return series.length ? series[series.length - 1] : null
}

function converted(account: Account): string | null {
  const point = lastPoint(account)
  if (!point || account.currency === refCurrency.value) return null
  const rate = rateFor(account.currency, refCurrency.value, rates.value)
  if (rate == null) return 'no rate'
  return formatAmount(point.amount * rate, refCurrency.value)
}

function freshness(account: Account): { label: string; level: string } {
  const days = freshnessDays(
    seriesByKey.value.get(account.key) || [],
    today.value
  )
  const level = freshnessLevel(days)
  const label = days == null ? 'never' : days === 0 ? 'today' : `${days} d ago`
  return { label, level: `fin-fresh--${level}` }
}

function manualSnapshots(account: Account): Entry[] {
  if (!account.entryId) return []
  return balanceEntries.value
    .filter(snapshot => snapshot.data.account_id === account.entryId)
    .sort((a, b) => (b.occurred_at || '').localeCompare(a.occurred_at || ''))
}

function txObservationCount(account: Account): number {
  const total = (seriesByKey.value.get(account.key) || []).length
  return Math.max(0, total - manualSnapshots(account).length)
}

function txCount(account: Account): number {
  return accountTxs(account, bankTxs.value).length
}

// The accounts <-> transactions bridge: jump to the Spending tab with the
// transactions list filtered on this account.
const txFocus = ref<string | null>(null)

async function showTransactions(account: Account) {
  txFocus.value = null
  tab.value = 'spending'
  await nextTick()
  txFocus.value = accountTxName(account)
  await nextTick()
  document.querySelector('.ftx')?.scrollIntoView?.({ behavior: 'smooth' })
}

// ----- account CRUD -----

const accountModalOpen = ref(false)
const accountName = ref('')
const accountType = ref<string>('bank')
const accountCurrency = ref('EUR')
const accountIdentifier = ref('')
const accountShared = ref(false)
const accountSaving = ref(false)

function openAccountModal() {
  accountName.value = ''
  accountType.value = 'bank'
  accountCurrency.value = refCurrency.value
  accountIdentifier.value = ''
  accountShared.value = false
  accountModalOpen.value = true
}

async function createAccount() {
  const name = accountName.value.trim()
  const currency = accountCurrency.value.trim().toUpperCase()
  if (!name || !currency) return
  accountSaving.value = true
  try {
    await ctx.api.entries.create({
      kind: 'account',
      source: 'finance_app',
      title: name,
      data: {
        type: accountType.value,
        currency,
        identifier: accountIdentifier.value.trim() || null,
        shared: accountShared.value
      }
    })
    accountEntries.value = await ctx.api.entries.list({
      kind: 'account',
      per_page: '200'
    })
    accountModalOpen.value = false
  } catch {
    // leave the modal open
  } finally {
    accountSaving.value = false
  }
}

// ponytail: deleting an account with manual snapshots is refused rather than
// cascading; delete the snapshots first (same rule as calendars).
async function deleteAccount(account: Account) {
  if (!account.entryId) return
  const snapshots = manualSnapshots(account)
  if (snapshots.length) {
    await ctx.confirm.ask({
      title: 'Account not empty',
      message: `"${account.name}" still has ${snapshots.length} snapshot(s). Delete them first.`,
      confirmLabel: 'OK'
    })
    return
  }
  const ok = await ctx.confirm.ask({
    message: `Delete account "${account.name}"?`,
    danger: true
  })
  if (!ok) return
  try {
    await ctx.api.entries.delete(account.entryId)
    accountEntries.value = accountEntries.value.filter(
      entry => entry.id !== account.entryId
    )
  } catch {
    // ignore
  }
}

// ----- snapshots -----

const snapshotFor = ref<string | null>(null) // account key with the open form
const snapshotAmount = ref('')
const snapshotDate = ref('')
const snapshotSaving = ref(false)
const expanded = ref<Set<string>>(new Set())

function openSnapshotForm(account: Account) {
  snapshotFor.value = account.key
  const last = lastPoint(account)
  snapshotAmount.value = last ? String(last.amount) : ''
  snapshotDate.value = today.value
}

async function addSnapshot(account: Account) {
  if (!account.entryId) return
  const amount = parseFloat(snapshotAmount.value.replace(',', '.'))
  if (!Number.isFinite(amount)) return
  snapshotSaving.value = true
  try {
    const created = await ctx.api.entries.create({
      kind: 'balance',
      source: 'finance_app',
      title: `${account.name}: ${formatAmount(amount, account.currency)}`,
      occurred_at: zonedToUtcISO(snapshotDate.value || today.value, '12:00'),
      data: { account_id: account.entryId, amount, currency: account.currency }
    })
    balanceEntries.value = [...balanceEntries.value, created]
    snapshotFor.value = null
  } catch {
    // keep the form open
  } finally {
    snapshotSaving.value = false
  }
}

async function deleteSnapshot(snapshot: Entry) {
  const ok = await ctx.confirm.ask({
    message: 'Delete this snapshot?',
    danger: true
  })
  if (!ok) return
  try {
    await ctx.api.entries.delete(snapshot.id)
    balanceEntries.value = balanceEntries.value.filter(
      entry => entry.id !== snapshot.id
    )
  } catch {
    // ignore
  }
}

function toggleExpanded(key: string) {
  if (expanded.value.has(key)) expanded.value.delete(key)
  else expanded.value.add(key)
  expanded.value = new Set(expanded.value)
}

function snapshotDateLabel(snapshot: Entry): string {
  return snapshot.occurred_at ? snapshot.occurred_at.slice(0, 10) : ''
}

function deltaLabel(delta: number): string {
  const sign = delta > 0 ? '+' : ''
  return `${sign}${formatAmount(delta, refCurrency.value)} / 30d`
}

function onTxUpdated(updated: Entry) {
  bankTxs.value = bankTxs.value.map(tx => (tx.id === updated.id ? updated : tx))
}

function onTxDeleted(id: string) {
  bankTxs.value = bankTxs.value.filter(tx => tx.id !== id)
}

// ----- cryptos tab: token + quantity over wallet accounts and snapshots -----

const cryptoToken = ref('')
const cryptoQty = ref('')
const cryptoSaving = ref(false)

const cryptoAccounts = computed(() =>
  accounts.value.filter(account => account.universe === 'crypto')
)

const parseQty = (raw: string) => {
  const qty = parseFloat(raw.replace(',', '.'))
  return Number.isFinite(qty) ? qty : null
}

async function recordQty(entryId: string, token: string, qty: number) {
  const created = await ctx.api.entries.create({
    kind: 'balance',
    source: 'finance_app',
    title: `${token}: ${qty}`,
    occurred_at: zonedToUtcISO(today.value, '12:00'),
    data: { account_id: entryId, amount: qty, currency: token }
  })
  balanceEntries.value = [...balanceEntries.value, created]
}

async function addCrypto() {
  const token = cryptoToken.value.trim().toUpperCase()
  const qty = parseQty(cryptoQty.value)
  if (!token || qty == null || cryptoSaving.value) return
  cryptoSaving.value = true
  try {
    // One wallet account per asset; adding an existing token records a
    // new quantity instead of duplicating the account.
    const existing = cryptoAccounts.value.find(
      account => account.entryId && account.currency === token
    )
    if (existing?.entryId) {
      await upsertQty(existing, qty)
    } else {
      const created = await ctx.api.entries.create({
        kind: 'account',
        source: 'finance_app',
        title: token,
        data: { type: 'wallet', currency: token }
      })
      accountEntries.value = [...accountEntries.value, created]
      await recordQty(created.id, token, qty)
    }
    cryptoToken.value = ''
    cryptoQty.value = ''
    void loadCryptoPrices()
  } catch {
    // keep the form values
  } finally {
    cryptoSaving.value = false
  }
}

async function updateQtyRecord(snapshot: Entry, account: Account, qty: number) {
  try {
    const updated = await ctx.api.entries.update(snapshot.id, {
      title: `${account.name}: ${qty}`,
      data: { ...snapshot.data, amount: qty }
    })
    balanceEntries.value = balanceEntries.value.map(entry =>
      entry.id === updated.id ? updated : entry
    )
  } catch {
    // ignore
  }
}

// New record, or correction of the same day's figure (no stacking).
async function upsertQty(account: Account, qty: number) {
  const todays = manualSnapshots(account).find(
    snapshot => snapshotDateLabel(snapshot) === today.value
  )
  if (todays) await updateQtyRecord(todays, account, qty)
  else await recordQty(account.entryId!, account.currency, qty)
}

async function setCryptoQty(account: Account, raw: string) {
  const qty = parseQty(raw)
  if (!account.entryId || qty == null || qty === lastPoint(account)?.amount)
    return
  try {
    await upsertQty(account, qty)
  } catch {
    // ignore
  }
}

function editQtyRecord(snapshot: Entry, account: Account, raw: string) {
  const qty = parseQty(raw)
  if (qty == null || qty === snapshot.data.amount) return
  void updateQtyRecord(snapshot, account, qty)
}

// ----- spot prices (display only; valuation stays on manual rates) -----

const cryptoPrices = ref<Record<string, number>>({})
const cryptoPricesLoading = ref(false)

async function loadCryptoPrices() {
  cryptoPricesLoading.value = true
  try {
    cryptoPrices.value = await fetchCryptoPrices(
      cryptoAccounts.value.map(account => account.currency),
      refCurrency.value
    )
  } catch {
    // offline or blocked: quantities alone still work
  } finally {
    cryptoPricesLoading.value = false
  }
}

// ----- portfolio total + value snapshots -----

// Expanded-set key for the portfolio history; account keys are UUIDs or
// "bank:<name>", so this can never collide.
const PORTFOLIO_KEY = 'portfolio:crypto'

const cryptoTotal = computed(() =>
  cryptoSpotTotal(
    cryptoAccounts.value,
    seriesByKey.value,
    cryptoPrices.value,
    rates.value,
    refCurrency.value
  )
)

const cryptoTotalLabel = computed(
  () =>
    (cryptoTotal.value.approx ? '≈ ' : '') +
    formatAmount(cryptoTotal.value.total, refCurrency.value)
)

const portfolioSnapshots = computed(() =>
  balanceEntries.value
    .filter(snapshot => snapshot.data.universe === 'crypto')
    .sort((a, b) => (b.occurred_at || '').localeCompare(a.occurred_at || ''))
)

function portfolioAmountLabel(snapshot: Entry): string {
  const amount = snapshot.data.amount
  if (typeof amount !== 'number') return ''
  const currency = (
    (snapshot.data.currency as string) || refCurrency.value
  ).toUpperCase()
  return formatAmount(amount, currency)
}

const cryptoSnapshotSaving = ref(false)

// Record the displayed total as a dated observation, with the same
// no-stacking rule as quantities: a second snapshot the same day corrects
// the day's entry.
async function snapshotPortfolio() {
  if (cryptoSnapshotSaving.value) return
  const amount = Math.round(cryptoTotal.value.total * 100) / 100
  const currency = refCurrency.value
  const title = `Crypto portfolio: ${amount} ${currency}`
  cryptoSnapshotSaving.value = true
  try {
    const todays = portfolioSnapshots.value.find(
      snapshot => snapshotDateLabel(snapshot) === today.value
    )
    if (todays) {
      const updated = await ctx.api.entries.update(todays.id, {
        title,
        data: { ...todays.data, amount, currency }
      })
      balanceEntries.value = balanceEntries.value.map(entry =>
        entry.id === updated.id ? updated : entry
      )
    } else {
      const created = await ctx.api.entries.create({
        kind: 'balance',
        source: 'finance_app',
        title,
        occurred_at: zonedToUtcISO(today.value, '12:00'),
        data: { universe: 'crypto', amount, currency }
      })
      balanceEntries.value = [...balanceEntries.value, created]
    }
  } catch {
    // nothing recorded; the button stays available for a retry
  } finally {
    cryptoSnapshotSaving.value = false
  }
}

watch(tab, next => {
  if (next === 'cryptos') void loadCryptoPrices()
})

// Manual rate first (it feeds the curve); spot price as a fallback hint.
function cryptoValue(account: Account): { text: string; spot: boolean } | null {
  const point = lastPoint(account)
  if (!point) return null
  const rate = rateFor(account.currency, refCurrency.value, rates.value)
  if (rate != null)
    return {
      text: formatAmount(point.amount * rate, refCurrency.value),
      spot: false
    }
  const price = cryptoPrices.value[account.currency]
  if (price != null)
    return {
      text: `≈ ${formatAmount(point.amount * price, refCurrency.value)}`,
      spot: true
    }
  return { text: 'no rate', spot: false }
}

// Unlike deleteAccount, deleting a token takes its history along: the
// cryptos tab is a quantity sheet, not an archive.
async function deleteCrypto(account: Account) {
  if (!account.entryId) return
  const snapshots = manualSnapshots(account)
  const ok = await ctx.confirm.ask({
    message: `Delete ${account.name} and its ${snapshots.length} record(s)?`,
    danger: true
  })
  if (!ok) return
  try {
    for (const snapshot of snapshots) await ctx.api.entries.delete(snapshot.id)
    await ctx.api.entries.delete(account.entryId)
    balanceEntries.value = balanceEntries.value.filter(
      snapshot => snapshot.data.account_id !== account.entryId
    )
    accountEntries.value = accountEntries.value.filter(
      entry => entry.id !== account.entryId
    )
  } catch {
    // partial deletes surface on reload
  }
}

async function patchAccount(account: Account, patch: Record<string, unknown>) {
  const entry = accountEntries.value.find(
    candidate => candidate.id === account.entryId
  )
  if (!entry) return
  try {
    const updated = await ctx.api.entries.update(entry.id, {
      data: { ...entry.data, ...patch }
    })
    accountEntries.value = accountEntries.value.map(item =>
      item.id === updated.id ? updated : item
    )
  } catch {
    // ignore
  }
}

// Saved on change; empty clears it and the account matches by name again.
function saveIdentifier(account: Account, raw: string) {
  void patchAccount(account, { identifier: raw.trim() || null })
}

function saveShared(account: Account, shared: boolean) {
  void patchAccount(account, { shared })
}
</script>

<template>
  <div class="fin-layout" :class="{ 'fin-layout--wide': tab === 'spending' }">
    <p v-if="loadState === 'loading'" class="fin-placeholder">
      Loading finance data…
    </p>
    <p v-else-if="loadState === 'error'" class="fin-placeholder">
      Failed to load finance data.
    </p>
    <template v-else>
      <div class="fin-tabs">
        <button
          v-for="option in TABS"
          :key="option.id"
          class="fin-tab"
          :class="{ 'fin-tab--active': tab === option.id }"
          @click="tab = option.id"
        >
          {{ option.label }}
        </button>
      </div>

      <OverviewView
        v-if="tab === 'overview'"
        :accounts="accounts"
        :series-by-key="seriesByKey"
        :balance-entries="balanceEntries"
        :txs="bankTxs"
        :rates="rates"
        :ref-currency="refCurrency"
        :today="today"
        @go="tab = $event"
      />

      <template v-else-if="tab === 'spending'">
        <SpendingView
          :txs="bankTxs"
          :accounts="accounts"
          :rates="rates"
          :ref-currency="refCurrency"
        />
        <TransactionsSection
          v-if="bankTxs.length"
          :ctx="ctx"
          :txs="bankTxs"
          :focus-account="txFocus"
          @updated="onTxUpdated"
          @deleted="onTxDeleted"
        />
      </template>

      <template v-else-if="tab === 'cryptos'">
        <form class="fin-crypto-add" @submit.prevent="addCrypto">
          <input
            v-model="cryptoToken"
            class="fin-crypto-token"
            placeholder="Token (BTC, ETH...)"
          />
          <input
            v-model="cryptoQty"
            class="fin-crypto-qty"
            placeholder="Quantity"
          />
          <button
            type="submit"
            class="fin-btn fin-btn--primary"
            :disabled="
              cryptoSaving || !cryptoToken.trim() || parseQty(cryptoQty) == null
            "
          >
            Add
          </button>
        </form>

        <div
          v-if="cryptoAccounts.length || portfolioSnapshots.length"
          class="fin-crypto-summary"
        >
          <span
            class="fin-account-caret"
            title="Snapshot history"
            @click="toggleExpanded(PORTFOLIO_KEY)"
          >
            {{ expanded.has(PORTFOLIO_KEY) ? '▾' : '▸' }}
          </span>
          <span class="fin-total-caption">total</span>
          <span class="fin-total">{{ cryptoTotalLabel }}</span>
          <span v-if="cryptoTotal.excluded.length" class="fin-warn">
            without {{ cryptoTotal.excluded.join(', ') }} (no price)
          </span>
          <span class="fin-toolbar-spacer"></span>
          <button
            class="fin-btn fin-crypto-snapshot"
            :disabled="
              cryptoSnapshotSaving ||
              cryptoPricesLoading ||
              !cryptoTotal.counted
            "
            title="Record the current total as a dated observation; it feeds the Overview curve"
            @click="snapshotPortfolio"
          >
            Snapshot
          </button>
        </div>
        <div
          v-if="
            (cryptoAccounts.length || portfolioSnapshots.length) &&
            expanded.has(PORTFOLIO_KEY)
          "
          class="fin-history"
        >
          <div
            v-for="snapshot in portfolioSnapshots"
            :key="snapshot.id"
            class="fin-history-row"
          >
            <span class="fin-history-date">{{
              snapshotDateLabel(snapshot)
            }}</span>
            <span class="fin-history-amount">{{
              portfolioAmountLabel(snapshot)
            }}</span>
            <button
              class="fin-mini-del"
              title="Delete snapshot"
              @click="deleteSnapshot(snapshot)"
            >
              ×
            </button>
          </div>
          <p v-if="!portfolioSnapshots.length" class="fin-history-note">
            No snapshots yet.
          </p>
        </div>

        <p v-if="!cryptoAccounts.length" class="fin-empty">
          No tokens yet. Enter a token and the quantity you hold; set its rate
          (Accounts tab) to value it.
        </p>

        <div v-else class="fin-accounts">
          <div
            v-for="account in cryptoAccounts"
            :key="account.key"
            class="fin-account"
          >
            <div class="fin-account-row">
              <span
                class="fin-account-caret"
                @click="toggleExpanded(account.key)"
              >
                {{ expanded.has(account.key) ? '▾' : '▸' }}
              </span>
              <span class="fin-crypto-name">{{ account.name }}</span>
              <span
                v-if="cryptoPrices[account.currency] != null"
                class="fin-crypto-price"
                title="Spot price (CoinGecko / DexScreener)"
              >
                {{ formatAmount(cryptoPrices[account.currency], refCurrency) }}
              </span>
              <span class="fin-account-amount">
                <input
                  :key="`${account.key}-${lastPoint(account)?.amount ?? ''}`"
                  class="fin-crypto-qty-input"
                  :value="lastPoint(account)?.amount ?? ''"
                  placeholder="quantity"
                  title="Type a new quantity to record it"
                  @change="
                    setCryptoQty(
                      account,
                      ($event.target as HTMLInputElement).value
                    )
                  "
                />
                <span
                  v-if="cryptoValue(account)"
                  class="fin-account-converted"
                  :title="
                    cryptoValue(account)!.spot
                      ? 'Spot estimate; set a rate (Accounts tab) to count it in the curve'
                      : ''
                  "
                >
                  {{ cryptoValue(account)!.text }}
                </span>
              </span>
              <button
                v-if="account.entryId"
                class="fin-mini-del"
                title="Delete token"
                @click="deleteCrypto(account)"
              >
                ×
              </button>
            </div>

            <div v-if="expanded.has(account.key)" class="fin-history">
              <div
                v-for="snapshot in manualSnapshots(account)"
                :key="snapshot.id"
                class="fin-history-row"
              >
                <span class="fin-history-date">{{
                  snapshotDateLabel(snapshot)
                }}</span>
                <input
                  :key="`${snapshot.id}-${snapshot.data.amount}`"
                  class="fin-crypto-qty-input"
                  :value="snapshot.data.amount"
                  title="Edit this record's quantity"
                  @change="
                    editQtyRecord(
                      snapshot,
                      account,
                      ($event.target as HTMLInputElement).value
                    )
                  "
                />
                <button
                  class="fin-mini-del"
                  title="Delete record"
                  @click="deleteSnapshot(snapshot)"
                >
                  ×
                </button>
              </div>
              <p
                v-if="!manualSnapshots(account).length"
                class="fin-history-note"
              >
                No records yet.
              </p>
            </div>
          </div>
        </div>
      </template>

      <template v-else>
        <div class="fin-toolbar">
          <label class="fin-ref">
            <span class="fin-ref-label">Reference</span>
            <ComboBox
              class="fin-ref-select"
              :model-value="refCurrency"
              :options="refCurrencyOptions"
              @update:model-value="onRefCurrencyChange"
            />
          </label>
          <button
            v-if="foreignCurrencies.length"
            class="fin-btn"
            title="Manual exchange rates to the reference currency"
            @click="openRates"
          >
            Rates
          </button>
          <span class="fin-toolbar-spacer"></span>
          <button class="fin-btn fin-btn--primary" @click="openAccountModal">
            + Account
          </button>
        </div>

        <p v-if="!accounts.length" class="fin-empty">
          No accounts yet. Create one (bank, cash, livret, broker or wallet) and
          record its balance; bank accounts imported through CSV appear here by
          themselves.
        </p>
        <p v-else class="fin-model-hint">
          One row per account, the curve is their sum. A balance is whatever was
          last observed: imported transactions carry one (the tx column opens an
          account's transactions), the other accounts you record with "record
          balance".
        </p>

        <section
          v-for="universe in universes"
          v-show="universe.accounts.length"
          :key="universe.universe"
          class="fin-universe"
        >
          <div class="fin-universe-head">
            <!-- Tradfi is the default universe: its name adds nothing. -->
            <h2
              v-if="universe.universe !== 'tradfi'"
              class="fin-universe-title"
              :style="{ color: universe.color }"
            >
              {{ universe.label }}
            </h2>
            <span class="fin-total-caption">total balance</span>
            <span class="fin-total">{{
              formatAmount(universe.total, refCurrency)
            }}</span>
            <span
              v-if="universe.points.length"
              class="fin-delta"
              :class="{ 'fin-delta--down': universe.delta30 < 0 }"
              title="Change over the last 30 days"
              >{{ deltaLabel(universe.delta30) }}</span
            >
          </div>
          <BalanceChart
            :points="universe.points"
            :end-date="today"
            :color="universe.color"
          />
          <p v-if="universe.excluded.length" class="fin-warn">
            No {{ refCurrency }} rate for:
            {{ universe.excluded.join(', ') }} (excluded from the curve)
          </p>

          <div class="fin-accounts">
            <div class="fin-account-row fin-account-row--head">
              <span class="fin-account-caret"></span>
              <span class="fin-account-name fin-col-label">account</span>
              <span class="fin-account-type fin-col-label">type</span>
              <span
                class="fin-tx-col fin-col-label"
                title="Imported transactions matched to this account"
                >tx</span
              >
              <span
                class="fin-fresh fin-col-label"
                title="Age of the last observation"
                >updated</span
              >
              <span class="fin-account-amount fin-col-label">last balance</span>
              <span class="fin-account-actions"></span>
            </div>
            <div
              v-for="account in universe.accounts"
              :key="account.key"
              class="fin-account"
            >
              <div class="fin-account-row">
                <span
                  class="fin-account-caret"
                  @click="toggleExpanded(account.key)"
                >
                  {{ expanded.has(account.key) ? '▾' : '▸' }}
                </span>
                <span
                  class="fin-account-name"
                  @click="toggleExpanded(account.key)"
                >
                  {{ account.name }}
                  <span
                    v-if="account.derived"
                    class="fin-badge"
                    title="Reconstructed from bank imports; create an account with this name to claim it"
                    >imported</span
                  >
                </span>
                <span class="fin-account-type">{{ account.type }}</span>
                <span class="fin-tx-col">
                  <button
                    v-if="txCount(account)"
                    class="fin-tx-btn"
                    title="Show this account's transactions"
                    @click="showTransactions(account)"
                  >
                    {{ txCount(account) }}
                  </button>
                  <template v-else>-</template>
                </span>
                <span
                  class="fin-fresh"
                  :class="freshness(account).level"
                  title="Age of the last observation"
                  >{{ freshness(account).label }}</span
                >
                <span class="fin-account-amount">
                  <template v-if="lastPoint(account)">
                    {{
                      formatAmount(lastPoint(account)!.amount, account.currency)
                    }}
                    <span
                      v-if="converted(account)"
                      class="fin-account-converted"
                    >
                      {{ converted(account) }}
                    </span>
                  </template>
                  <template v-else>no data</template>
                </span>
                <span class="fin-account-actions">
                  <button
                    v-if="account.entryId"
                    class="fin-mini-btn"
                    title="Record the balance you see at the bank today"
                    @click="openSnapshotForm(account)"
                  >
                    record balance
                  </button>
                  <button
                    v-if="account.entryId"
                    class="fin-mini-del"
                    title="Delete account"
                    @click="deleteAccount(account)"
                  >
                    ×
                  </button>
                </span>
              </div>

              <form
                v-if="snapshotFor === account.key"
                class="fin-snapshot-form"
                @submit.prevent="addSnapshot(account)"
              >
                <input
                  v-model="snapshotAmount"
                  class="fin-snap-amount"
                  :placeholder="`Amount (${account.currency})`"
                  autofocus
                />
                <DateInput v-model="snapshotDate" class="fin-snap-date" />
                <button
                  type="submit"
                  class="fin-btn fin-btn--primary"
                  :disabled="snapshotSaving"
                >
                  Save
                </button>
                <button
                  type="button"
                  class="fin-btn"
                  @click="snapshotFor = null"
                >
                  Cancel
                </button>
              </form>

              <div v-if="expanded.has(account.key)" class="fin-history">
                <div v-if="account.entryId" class="fin-ident-row">
                  <label class="fin-ident-label" :for="`ident-${account.key}`"
                    >tx account</label
                  >
                  <input
                    :id="`ident-${account.key}`"
                    class="fin-ident-input"
                    :value="account.identifier || ''"
                    placeholder="name carried by imported transactions"
                    title="Transactions whose account matches this name feed this account's balance"
                    @change="
                      saveIdentifier(
                        account,
                        ($event.target as HTMLInputElement).value
                      )
                    "
                  /><span v-if="!account.identifier" class="fin-ident-hint"
                    >matches by account name when empty</span
                  >
                  <label class="fin-shared-toggle">
                    <input
                      type="checkbox"
                      :checked="account.shared"
                      @change="
                        saveShared(
                          account,
                          ($event.target as HTMLInputElement).checked
                        )
                      "
                    />
                    shared (spending counts half)
                  </label>
                </div>
                <div
                  v-for="snapshot in manualSnapshots(account)"
                  :key="snapshot.id"
                  class="fin-history-row"
                >
                  <span class="fin-history-date">{{
                    snapshotDateLabel(snapshot)
                  }}</span>
                  <span>{{
                    formatAmount(
                      snapshot.data.amount as number,
                      account.currency
                    )
                  }}</span>
                  <button
                    class="fin-mini-del"
                    title="Delete snapshot"
                    @click="deleteSnapshot(snapshot)"
                  >
                    ×
                  </button>
                </div>
                <p v-if="txObservationCount(account)" class="fin-history-note">
                  + {{ txObservationCount(account) }} balance point(s) from bank
                  imports
                </p>
                <p
                  v-if="
                    !manualSnapshots(account).length &&
                    !txObservationCount(account)
                  "
                  class="fin-history-note"
                >
                  No snapshots yet.
                </p>
              </div>
            </div>
          </div>
        </section>

        <p v-if="bothUniversesLive" class="fin-grand">
          ALL UNIVERSES: {{ formatAmount(grandTotal, refCurrency) }}
        </p>
      </template>
    </template>
  </div>

  <Teleport to="body">
    <dialog
      v-if="accountModalOpen"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="fin-account-title"
      @click.self="accountModalOpen = false"
      @cancel="accountModalOpen = false"
    >
      <div class="fin-modal">
        <div id="fin-account-title" class="fin-modal-header">New account</div>
        <div class="fin-modal-field">
          <label>Name</label>
          <input
            v-model="accountName"
            placeholder="e.g. Livret A, Ledger ETH"
            @keydown.enter="createAccount"
          />
        </div>
        <div class="fin-modal-row">
          <div class="fin-modal-field">
            <label>Type</label>
            <ComboBox v-model="accountType" :options="ACCOUNT_TYPES" />
          </div>
          <div class="fin-modal-field">
            <label>Currency / asset</label>
            <input v-model="accountCurrency" placeholder="EUR, USD, ETH…" />
          </div>
        </div>
        <div class="fin-modal-field">
          <label>Transactions account (optional)</label>
          <input
            v-model="accountIdentifier"
            placeholder="account name carried by imported transactions"
          />
        </div>
        <label class="fin-shared-toggle fin-modal-shared">
          <input v-model="accountShared" type="checkbox" />
          Shared account (spending counts half)
        </label>
        <p class="fin-modal-hint">
          Wallets live in the crypto universe; use the asset as currency (one
          account per asset) and set its rate to value it.
        </p>
        <div class="fin-modal-actions">
          <span class="fin-modal-spacer"></span>
          <button class="fin-btn" @click="accountModalOpen = false">
            Cancel
          </button>
          <button
            class="fin-btn fin-btn--primary"
            :disabled="accountSaving || !accountName.trim()"
            @click="createAccount"
          >
            Create
          </button>
        </div>
      </div>
    </dialog>

    <dialog
      v-if="ratesOpen"
      :ref="openDialog"
      class="modal-dialog"
      aria-labelledby="fin-rates-title"
      @click.self="ratesOpen = false"
      @cancel="ratesOpen = false"
    >
      <div class="fin-modal">
        <div id="fin-rates-title" class="fin-modal-header">Exchange rates</div>
        <div
          v-for="currency in foreignCurrencies"
          :key="currency"
          class="fin-modal-field fin-rate-row"
        >
          <label>1 {{ currency }} =</label>
          <input
            v-model="ratesDraft[currency]"
            class="fin-rate-input"
            :placeholder="`? ${refCurrency}`"
          />
          <span class="fin-rate-unit">{{ refCurrency }}</span>
        </div>
        <p class="fin-modal-hint">
          Rates are entered by hand and dated by you; totals are only as fresh
          as these numbers.
        </p>
        <div class="fin-modal-actions">
          <span class="fin-modal-spacer"></span>
          <button class="fin-btn" @click="ratesOpen = false">Cancel</button>
          <button class="fin-btn fin-btn--primary" @click="saveRates">
            Save
          </button>
        </div>
      </div>
    </dialog>
  </Teleport>
</template>

<style scoped>
.fin-layout {
  padding: 1rem 1.25rem;
  max-width: 860px;
  height: 100vh;
  overflow-y: auto;
}
/* Spending wants the full width for its chart and table. */
.fin-layout--wide {
  max-width: none;
}
.fin-crypto-add {
  display: flex;
  gap: 0.5rem;
  margin-bottom: 1.25rem;
}
.fin-crypto-token {
  width: 180px;
}
.fin-crypto-qty {
  width: 160px;
}
.fin-crypto-name {
  font-family: var(--font-mono);
  font-weight: 600;
}
.fin-crypto-price {
  font-family: var(--font-mono);
  font-size: 0.78rem;
  color: var(--text-muted);
}
.fin-crypto-qty-input {
  width: 140px;
  font-family: var(--font-mono);
  font-size: 0.85rem;
  text-align: right;
  padding: 0.15rem 0.4rem;
}
.fin-crypto-summary {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0.75rem 0 0.25rem;
}
.fin-history-amount {
  font-variant-numeric: tabular-nums;
}
.fin-placeholder,
.fin-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.88rem;
  padding: 2rem 0;
}
.fin-tabs {
  display: flex;
  gap: 0.25rem;
  border-bottom: 1px solid var(--border);
  margin-bottom: 1rem;
}
.fin-tab {
  background: transparent;
  border: none;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  padding: 0.5rem 0.9rem;
  cursor: pointer;
  border-radius: 0;
}
.fin-tab:hover {
  color: var(--text);
}
.fin-tab--active {
  color: var(--primary);
  box-shadow: inset 0 -2px 0 var(--primary);
}
.fin-toolbar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1.25rem;
}
.fin-toolbar-spacer {
  flex: 1;
}
.fin-ref {
  display: flex;
  align-items: center;
  gap: 0.45rem;
}
.fin-ref-select {
  width: 110px;
}
.fin-ref-label {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}
.fin-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  padding: 0.35rem 0.8rem;
  border-radius: 8px;
  font-size: 0.85rem;
  cursor: pointer;
  white-space: nowrap;
}
.fin-btn:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.fin-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}
.fin-btn--primary:hover:not(:disabled) {
  color: var(--primary-contrast);
  background: var(--primary-hover);
}
.fin-btn:disabled {
  opacity: 0.5;
  cursor: default;
}

/* Universe blocks */
.fin-universe {
  margin-bottom: 2rem;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.15rem;
  background: var(--bg-surface);
}
.fin-universe-head {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
  margin-bottom: 0.5rem;
}
.fin-universe-title {
  margin: 0;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.3rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.fin-total {
  font-family: var(--font-mono);
  font-size: 1.15rem;
  font-weight: 600;
}
.fin-delta {
  font-family: var(--font-mono);
  font-size: 0.78rem;
  color: var(--success, #4fd674);
}
.fin-delta--down {
  color: var(--danger);
}
.fin-warn {
  color: var(--danger);
  font-size: 0.8rem;
  font-family: var(--font-mono);
  margin: 0.35rem 0 0;
}

/* Accounts */
.fin-accounts {
  margin-top: 0.75rem;
  display: flex;
  flex-direction: column;
}
.fin-account {
  border-top: 1px solid var(--border);
}
.fin-account-row {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  padding: 0.5rem 0.25rem;
  font-size: 0.92rem;
}
.fin-account-caret {
  color: var(--text-muted);
  cursor: pointer;
  flex-shrink: 0;
  width: 0.9em;
}
.fin-account-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
.fin-account-row--head .fin-account-name {
  cursor: default;
}
.fin-badge {
  font-family: var(--font-mono);
  font-size: 0.65rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0 0.3em;
}
.fin-account-type {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  flex-shrink: 0;
  width: 60px;
}
.fin-model-hint {
  color: var(--text-muted);
  font-size: 0.8rem;
  margin: -0.5rem 0 1rem;
}
.fin-total-caption {
  font-family: var(--font-mono);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}
.fin-account-row--head {
  padding-bottom: 0.15rem;
}
.fin-col-label {
  font-family: var(--font-mono);
  font-size: 0.68rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  flex-shrink: 0;
}
.fin-account-actions {
  display: flex;
  justify-content: flex-end;
  gap: 0.35rem;
  width: 150px;
  flex-shrink: 0;
}
.fin-tx-col {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  flex-shrink: 0;
  width: 52px;
}
.fin-tx-btn {
  border: none;
  background: transparent;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  padding: 0;
  cursor: pointer;
  text-decoration: underline dotted;
}
.fin-tx-btn:hover {
  color: var(--primary);
}
.fin-fresh {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  flex-shrink: 0;
  width: 68px;
}
.fin-fresh--ok {
  color: var(--success, #4fd674);
}
.fin-fresh--warn {
  color: #ffb454;
}
.fin-fresh--stale {
  color: var(--danger);
}
.fin-account-amount {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 0.88rem;
  flex-shrink: 0;
}
.fin-account-converted {
  color: var(--text-muted);
  font-size: 0.75rem;
  margin-left: 0.4rem;
}
.fin-mini-btn {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  border-radius: 6px;
  padding: 0.1rem 0.5rem;
  font-size: 0.72rem;
  cursor: pointer;
  flex-shrink: 0;
}
.fin-mini-btn:hover {
  border-color: var(--primary);
  color: var(--primary);
}
.fin-mini-del {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.25rem;
  flex-shrink: 0;
}
.fin-mini-del:hover {
  color: var(--danger);
}

/* Snapshot form + history */
.fin-snapshot-form {
  display: flex;
  gap: 0.5rem;
  padding: 0.25rem 0.25rem 0.6rem 1.5rem;
}
.fin-snap-amount {
  width: 160px;
}
.fin-snap-date {
  width: 150px;
}
.fin-history {
  padding: 0 0.25rem 0.6rem 1.5rem;
}
.fin-ident-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0 0.4rem;
}
.fin-ident-label {
  font-family: var(--font-mono);
  font-size: 0.7rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  flex-shrink: 0;
}
.fin-ident-input {
  width: 260px;
  font-size: 0.8rem;
  padding: 0.15rem 0.4rem;
}
.fin-ident-hint {
  font-size: 0.72rem;
  color: var(--text-muted);
}
.fin-shared-toggle {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.8rem;
  color: var(--text);
  cursor: pointer;
  white-space: nowrap;
}
.fin-shared-toggle input {
  width: 14px;
  height: 14px;
  margin: 0;
  accent-color: var(--primary);
}
.fin-modal-shared {
  margin-bottom: 0.75rem;
}
.fin-history-row {
  display: flex;
  align-items: baseline;
  gap: 0.75rem;
  font-family: var(--font-mono);
  font-size: 0.8rem;
  padding: 0.15rem 0;
}
.fin-history-date {
  color: var(--text-muted);
}
.fin-history-note {
  color: var(--text-muted);
  font-size: 0.75rem;
  font-family: var(--font-mono);
  margin: 0.25rem 0 0;
}

/* Footer combined total: present but never the headline */
.fin-grand {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  text-align: right;
  margin: 0 0 1rem;
}

/* Modals */
.fin-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1.25rem;
  width: 100%;
  max-width: 400px;
}
.fin-modal-header {
  font-weight: 600;
  font-size: 1.05rem;
  margin-bottom: 1rem;
}
.fin-modal-field {
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
  margin-bottom: 0.75rem;
}
.fin-modal-field label {
  font-size: 0.85rem;
  color: var(--text-muted);
}
.fin-modal-row {
  display: flex;
  gap: 0.75rem;
}
.fin-modal-row .fin-modal-field {
  flex: 1;
}
.fin-modal-hint {
  color: var(--text-muted);
  font-size: 0.78rem;
  margin: 0 0 0.75rem;
}
.fin-modal-actions {
  display: flex;
  gap: 0.5rem;
  margin-top: 0.5rem;
}
.fin-modal-spacer {
  flex: 1;
}
.fin-rate-row {
  flex-direction: row;
  align-items: center;
  gap: 0.5rem;
}
.fin-rate-row label {
  width: 70px;
  flex-shrink: 0;
  font-family: var(--font-mono);
}
.fin-rate-input {
  flex: 1;
  min-width: 0;
}
.fin-rate-unit {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.85rem;
}
</style>
