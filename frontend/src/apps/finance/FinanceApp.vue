<script setup lang="ts">
import { ref, computed, reactive, onMounted } from 'vue'
import type { AppContext, Entry } from '../types'
import { todayInUserTz, zonedToUtcISO } from '../../lib/datetime'
import { addDays } from '../calendar/recurrence'
import ComboBox from '../../components/ComboBox.vue'
import BalanceChart from './BalanceChart.vue'
import SpendingView from './SpendingView.vue'
import TransactionsSection from './TransactionsSection.vue'
import {
  ACCOUNT_TYPES,
  buildAccounts,
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

const props = defineProps<{ ctx: AppContext }>()
const ctx = props.ctx

const CRYPTO_COLOR = '#6ccec9'

// ----- data -----

type Tab = 'accounts' | 'spending'
const tab = ref<Tab>('accounts')
const TABS: Array<{ id: Tab; label: string }> = [
  { id: 'accounts', label: 'Accounts' },
  { id: 'spending', label: 'Spending' }
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
    prefs.value = prefsList.find(p => p.title === 'finance') || null
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

function onRefCurrencyChange(v: string) {
  void savePrefs({ reference_currency: v })
}

const refCurrencyOptions = computed(() => {
  const set = new Set(['EUR', 'USD', 'GBP', 'CHF'])
  for (const a of accounts.value)
    if (a.universe === 'tradfi') set.add(a.currency)
  set.add(refCurrency.value)
  return [...set].sort()
})

// ----- rates editor -----

const ratesOpen = ref(false)
const ratesDraft = reactive<Record<string, string>>({})

const foreignCurrencies = computed(() =>
  [...new Set(accounts.value.map(a => a.currency))]
    .filter(c => c !== refCurrency.value)
    .sort()
)

function openRates() {
  for (const key of Object.keys(ratesDraft)) delete ratesDraft[key]
  for (const c of foreignCurrencies.value) {
    ratesDraft[c] = rates.value[c] != null ? String(rates.value[c]) : ''
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
  const m = new Map<string, SnapshotPoint[]>()
  for (const a of accounts.value) {
    m.set(a.key, snapshotSeries(a, balanceEntries.value, bankTxs.value))
  }
  return m
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
  const list = accounts.value.filter(a => a.universe === universe)
  const { points, excluded } = universeCurve(
    list,
    seriesByKey.value,
    rates.value,
    refCurrency.value
  )
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
  universes.value.reduce((sum, u) => sum + u.total, 0)
)
const bothUniversesLive = computed(() =>
  universes.value.every(u => u.points.length > 0)
)

// ----- per-account helpers -----

function lastPoint(a: Account): SnapshotPoint | null {
  const series = seriesByKey.value.get(a.key) || []
  return series.length ? series[series.length - 1] : null
}

function converted(a: Account): string | null {
  const point = lastPoint(a)
  if (!point || a.currency === refCurrency.value) return null
  const rate = rateFor(a.currency, refCurrency.value, rates.value)
  if (rate == null) return 'no rate'
  return formatAmount(point.amount * rate, refCurrency.value)
}

function freshness(a: Account): { label: string; level: string } {
  const days = freshnessDays(seriesByKey.value.get(a.key) || [], today.value)
  const level = freshnessLevel(days)
  const label = days == null ? 'never' : days === 0 ? 'today' : `${days} d`
  return { label, level: `fin-fresh--${level}` }
}

function manualSnapshots(a: Account): Entry[] {
  if (!a.entryId) return []
  return balanceEntries.value
    .filter(b => b.data.account_id === a.entryId)
    .sort((x, y) => (y.occurred_at || '').localeCompare(x.occurred_at || ''))
}

function txObservationCount(a: Account): number {
  const total = (seriesByKey.value.get(a.key) || []).length
  return Math.max(0, total - manualSnapshots(a).length)
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
async function deleteAccount(a: Account) {
  if (!a.entryId) return
  const snapshots = manualSnapshots(a)
  if (snapshots.length) {
    await ctx.confirm.ask({
      title: 'Account not empty',
      message: `"${a.name}" still has ${snapshots.length} snapshot(s). Delete them first.`,
      confirmLabel: 'OK'
    })
    return
  }
  const ok = await ctx.confirm.ask({
    message: `Delete account "${a.name}"?`,
    danger: true
  })
  if (!ok) return
  try {
    await ctx.api.entries.delete(a.entryId)
    accountEntries.value = accountEntries.value.filter(e => e.id !== a.entryId)
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

function openSnapshotForm(a: Account) {
  snapshotFor.value = a.key
  const last = lastPoint(a)
  snapshotAmount.value = last ? String(last.amount) : ''
  snapshotDate.value = today.value
}

async function addSnapshot(a: Account) {
  if (!a.entryId) return
  const amount = parseFloat(snapshotAmount.value.replace(',', '.'))
  if (!Number.isFinite(amount)) return
  snapshotSaving.value = true
  try {
    const created = await ctx.api.entries.create({
      kind: 'balance',
      source: 'finance_app',
      title: `${a.name}: ${formatAmount(amount, a.currency)}`,
      occurred_at: zonedToUtcISO(snapshotDate.value || today.value, '12:00'),
      data: { account_id: a.entryId, amount, currency: a.currency }
    })
    balanceEntries.value = [...balanceEntries.value, created]
    snapshotFor.value = null
  } catch {
    // keep the form open
  } finally {
    snapshotSaving.value = false
  }
}

async function deleteSnapshot(b: Entry) {
  const ok = await ctx.confirm.ask({
    message: 'Delete this snapshot?',
    danger: true
  })
  if (!ok) return
  try {
    await ctx.api.entries.delete(b.id)
    balanceEntries.value = balanceEntries.value.filter(x => x.id !== b.id)
  } catch {
    // ignore
  }
}

function toggleExpanded(key: string) {
  if (expanded.value.has(key)) expanded.value.delete(key)
  else expanded.value.add(key)
  expanded.value = new Set(expanded.value)
}

function snapshotDateLabel(b: Entry): string {
  return b.occurred_at ? b.occurred_at.slice(0, 10) : ''
}

function deltaLabel(delta: number): string {
  const sign = delta > 0 ? '+' : ''
  return `${sign}${formatAmount(delta, refCurrency.value)} / 30d`
}

function onTxUpdated(updated: Entry) {
  bankTxs.value = bankTxs.value.map(t => (t.id === updated.id ? updated : t))
}

function onTxDeleted(id: string) {
  bankTxs.value = bankTxs.value.filter(t => t.id !== id)
}

async function patchAccount(a: Account, patch: Record<string, unknown>) {
  const entry = accountEntries.value.find(e => e.id === a.entryId)
  if (!entry) return
  try {
    const updated = await ctx.api.entries.update(entry.id, {
      data: { ...entry.data, ...patch }
    })
    accountEntries.value = accountEntries.value.map(e =>
      e.id === updated.id ? updated : e
    )
  } catch {
    // ignore
  }
}

// Saved on change; empty clears it and the account matches by name again.
function saveIdentifier(a: Account, raw: string) {
  void patchAccount(a, { identifier: raw.trim() || null })
}

function saveShared(a: Account, shared: boolean) {
  void patchAccount(a, { shared })
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
          v-for="t in TABS"
          :key="t.id"
          class="fin-tab"
          :class="{ 'fin-tab--active': tab === t.id }"
          @click="tab = t.id"
        >
          {{ t.label }}
        </button>
      </div>

      <template v-if="tab === 'spending'">
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
          @updated="onTxUpdated"
          @deleted="onTxDeleted"
        />
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

        <section
          v-for="u in universes"
          v-show="u.accounts.length"
          :key="u.universe"
          class="fin-universe"
        >
          <div class="fin-universe-head">
            <h2 class="fin-universe-title" :style="{ color: u.color }">
              {{ u.label }}
            </h2>
            <span class="fin-total">{{
              formatAmount(u.total, refCurrency)
            }}</span>
            <span
              v-if="u.points.length"
              class="fin-delta"
              :class="{ 'fin-delta--down': u.delta30 < 0 }"
              >{{ deltaLabel(u.delta30) }}</span
            >
          </div>
          <BalanceChart :points="u.points" :end-date="today" :color="u.color" />
          <p v-if="u.excluded.length" class="fin-warn">
            No {{ refCurrency }} rate for: {{ u.excluded.join(', ') }} (excluded
            from the curve)
          </p>

          <div class="fin-accounts">
            <div v-for="a in u.accounts" :key="a.key" class="fin-account">
              <div class="fin-account-row">
                <span class="fin-account-caret" @click="toggleExpanded(a.key)">
                  {{ expanded.has(a.key) ? '▾' : '▸' }}
                </span>
                <span class="fin-account-name" @click="toggleExpanded(a.key)">
                  {{ a.name }}
                  <span
                    v-if="a.derived"
                    class="fin-badge"
                    title="Reconstructed from bank CSV imports"
                    >csv</span
                  >
                </span>
                <span class="fin-account-type">{{ a.type }}</span>
                <span class="fin-fresh" :class="freshness(a).level">{{
                  freshness(a).label
                }}</span>
                <span class="fin-account-amount">
                  <template v-if="lastPoint(a)">
                    {{ formatAmount(lastPoint(a)!.amount, a.currency) }}
                    <span v-if="converted(a)" class="fin-account-converted">
                      {{ converted(a) }}
                    </span>
                  </template>
                  <template v-else>no data</template>
                </span>
                <button
                  v-if="a.entryId"
                  class="fin-mini-btn"
                  title="Record a balance snapshot"
                  @click="openSnapshotForm(a)"
                >
                  + snapshot
                </button>
                <button
                  v-if="a.entryId"
                  class="fin-mini-del"
                  title="Delete account"
                  @click="deleteAccount(a)"
                >
                  ×
                </button>
              </div>

              <form
                v-if="snapshotFor === a.key"
                class="fin-snapshot-form"
                @submit.prevent="addSnapshot(a)"
              >
                <input
                  v-model="snapshotAmount"
                  class="fin-snap-amount"
                  :placeholder="`Amount (${a.currency})`"
                  autofocus
                />
                <input
                  v-model="snapshotDate"
                  type="date"
                  class="fin-snap-date"
                />
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

              <div v-if="expanded.has(a.key)" class="fin-history">
                <div v-if="a.entryId" class="fin-ident-row">
                  <label class="fin-ident-label" :for="`ident-${a.key}`"
                    >tx account</label
                  >
                  <input
                    :id="`ident-${a.key}`"
                    class="fin-ident-input"
                    :value="a.identifier || ''"
                    placeholder="name carried by imported transactions"
                    title="Transactions whose account matches this name feed this account's balance"
                    @change="
                      saveIdentifier(
                        a,
                        ($event.target as HTMLInputElement).value
                      )
                    "
                  /><span v-if="!a.identifier" class="fin-ident-hint"
                    >matches by account name when empty</span
                  >
                  <label class="fin-shared-toggle">
                    <input
                      type="checkbox"
                      :checked="a.shared"
                      @change="
                        saveShared(
                          a,
                          ($event.target as HTMLInputElement).checked
                        )
                      "
                    />
                    shared (spending counts half)
                  </label>
                </div>
                <div
                  v-for="b in manualSnapshots(a)"
                  :key="b.id"
                  class="fin-history-row"
                >
                  <span class="fin-history-date">{{
                    snapshotDateLabel(b)
                  }}</span>
                  <span>{{
                    formatAmount(b.data.amount as number, a.currency)
                  }}</span>
                  <button
                    class="fin-mini-del"
                    title="Delete snapshot"
                    @click="deleteSnapshot(b)"
                  >
                    ×
                  </button>
                </div>
                <p v-if="txObservationCount(a)" class="fin-history-note">
                  + {{ txObservationCount(a) }} balance point(s) from bank
                  imports
                </p>
                <p
                  v-if="!manualSnapshots(a).length && !txObservationCount(a)"
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
    <div
      v-if="accountModalOpen"
      class="fin-modal-overlay"
      @click.self="accountModalOpen = false"
    >
      <div class="fin-modal">
        <div class="fin-modal-header">New account</div>
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
    </div>

    <div
      v-if="ratesOpen"
      class="fin-modal-overlay"
      @click.self="ratesOpen = false"
    >
      <div class="fin-modal">
        <div class="fin-modal-header">Exchange rates</div>
        <div
          v-for="c in foreignCurrencies"
          :key="c"
          class="fin-modal-field fin-rate-row"
        >
          <label>1 {{ c }} =</label>
          <input
            v-model="ratesDraft[c]"
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
    </div>
  </Teleport>
</template>

<style scoped>
.fin-layout {
  padding: 1rem 1.25rem;
  max-width: 860px;
  height: calc(100vh - 4rem);
  overflow-y: auto;
}
/* Spending wants the full width for its chart and table. */
.fin-layout--wide {
  max-width: none;
}
.fin-placeholder,
.fin-empty {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 1.15rem;
  font-weight: 600;
}
.fin-delta {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.78rem;
  color: var(--success, #4fd674);
}
.fin-delta--down {
  color: var(--danger);
}
.fin-warn {
  color: var(--danger);
  font-size: 0.8rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  cursor: pointer;
}
.fin-badge {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.65rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 0 0.3em;
}
.fin-account-type {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  flex-shrink: 0;
}
.fin-fresh {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  flex-shrink: 0;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  padding: 0.15rem 0;
}
.fin-history-date {
  color: var(--text-muted);
}
.fin-history-note {
  color: var(--text-muted);
  font-size: 0.75rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  margin: 0.25rem 0 0;
}

/* Footer combined total: present but never the headline */
.fin-grand {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  letter-spacing: 0.08em;
  color: var(--text-muted);
  text-align: right;
  margin: 0 0 1rem;
}

/* Modals */
.fin-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 100;
  display: flex;
  align-items: center;
  justify-content: center;
}
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.fin-rate-input {
  flex: 1;
  min-width: 0;
}
.fin-rate-unit {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.85rem;
}
</style>
