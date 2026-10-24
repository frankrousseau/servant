import type { Entry } from '../types'
import { utcToZonedParts } from '../../lib/datetime'

// Pure logic for the Finance app. Core principle: a balance is an
// observation (snapshot), never a derivation from transactions. Bank CSV
// imports already contain a balance-after-transaction, so bank accounts get
// their history at no cost. For all other accounts, the user records the
// snapshots by hand.

export type Universe = 'tradfi' | 'crypto'
export type AccountType = 'bank' | 'cash' | 'livret' | 'broker' | 'wallet'

export const ACCOUNT_TYPES: AccountType[] = [
  'bank',
  'cash',
  'livret',
  'broker',
  'wallet'
]

export interface Account {
  key: string // entity id, or "bank:<name>" when derived from bank_tx
  entryId: string | null // set when entity-backed
  name: string
  // The account name that the imported transactions contain (data.account).
  // It lets an entity claim transactions when its display name is different
  // from the name in the CSV.
  identifier: string | null
  // Shared with another person: spending counts half. Balances stay whole,
  // because they are real observations of the real account.
  shared: boolean
  type: AccountType
  currency: string
  universe: Universe
  derived: boolean // reconstructed from bank_tx imports, no entity behind it
}

export interface SnapshotPoint {
  date: string // civil YYYY-MM-DD in the user's timezone
  amount: number // in the account's currency
}

// The value of 1 unit of a currency in reference-currency units. The
// reference itself is always 1, and the app never stores it.
export type Rates = Record<string, number>

export const universeOf = (type: AccountType): Universe =>
  type === 'wallet' ? 'crypto' : 'tradfi'

const norm = (name: string) => name.trim().toLowerCase()

function txAccountName(tx: Entry): string {
  return ((tx.data.account as string) || '').trim()
}

function txBalance(tx: Entry): number | null {
  const b = tx.data.balance
  return typeof b === 'number' && Number.isFinite(b) ? b : null
}

function txAmount(tx: Entry): number | null {
  const a = tx.data.amount
  return typeof a === 'number' && Number.isFinite(a) ? a : null
}

// The name that an account uses to match transactions.
export const accountTxName = (a: Account) => a.identifier || a.name

export function accountTxs(account: Account, bankTxs: Entry[]): Entry[] {
  const key = norm(accountTxName(account))
  return bankTxs.filter(tx => norm(txAccountName(tx)) === key)
}

// Returns the entity-backed accounts (kind "account") plus the accounts
// derived from bank_tx data.account (same pattern as synced calendar
// agendas). An entity whose name matches a CSV account claims it. The entity
// then absorbs the transaction-derived history and can also take manual
// snapshots.
export function buildAccounts(
  accountEntries: Entry[],
  bankTxs: Entry[]
): Account[] {
  const out: Account[] = []
  const claimed = new Set<string>()

  for (const e of accountEntries) {
    const type = (e.data.type as AccountType) || 'bank'
    const identifier = ((e.data.identifier as string) || '').trim() || null
    out.push({
      key: e.id,
      entryId: e.id,
      name: (e.title || 'Unnamed').trim(),
      identifier,
      shared: e.data.shared === true,
      type,
      currency: ((e.data.currency as string) || 'EUR').trim().toUpperCase(),
      universe: universeOf(type),
      derived: false
    })
    claimed.add(norm(e.title || ''))
    if (identifier) claimed.add(norm(identifier))
  }

  const seen = new Set<string>()
  for (const tx of bankTxs) {
    const name = txAccountName(tx)
    if (!name || seen.has(norm(name)) || claimed.has(norm(name))) continue
    if (txBalance(tx) == null) continue
    seen.add(norm(name))
    out.push({
      key: `bank:${norm(name)}`,
      entryId: null,
      name,
      identifier: null,
      shared: false,
      type: 'bank',
      currency: ((tx.data.currency as string) || 'EUR').trim().toUpperCase(),
      universe: 'tradfi',
      derived: true
    })
  }

  return out.sort((a, b) =>
    a.name.toLowerCase().localeCompare(b.name.toLowerCase())
  )
}

// Returns the snapshot series for one account, in ascending order. There is
// one point for each day: the latest observation of the day wins. The sources
// are the manual balance entries (data.account_id) and the
// balance-after-transaction of the bank_tx imports. The imports must match
// the bank account name (the identifier of the account, or its name). After
// the last observation, the function projects the series forward: it applies
// the amounts of the later transactions. As a result, the current value stays
// live between snapshots.
export function snapshotSeries(
  account: Account,
  balanceEntries: Entry[],
  bankTxs: Entry[]
): SnapshotPoint[] {
  const txs = accountTxs(account, bankTxs)
  const observations: { at: string; date: string; amount: number }[] = []
  let lastObservedAt = ''

  for (const tx of txs) {
    const balance = txBalance(tx)
    if (balance == null || !tx.occurred_at) continue
    observations.push({
      at: tx.occurred_at,
      date: utcToZonedParts(tx.occurred_at).date,
      amount: balance
    })
    if (tx.occurred_at > lastObservedAt) lastObservedAt = tx.occurred_at
  }

  if (account.entryId) {
    for (const b of balanceEntries) {
      if (b.data.account_id !== account.entryId) continue
      const amount = b.data.amount
      if (typeof amount !== 'number' || !b.occurred_at) continue
      observations.push({
        // Manual snapshots outrank same-instant tx balances.
        at: b.occurred_at + '~manual',
        date: utcToZonedParts(b.occurred_at).date,
        amount
      })
      if (b.occurred_at > lastObservedAt) lastObservedAt = b.occurred_at
    }
  }

  observations.sort((a, b) => a.at.localeCompare(b.at))
  const byDay = new Map<string, number>()
  for (const o of observations) byDay.set(o.date, o.amount)

  const materialize = () =>
    [...byDay.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([date, amount]) => ({ date, amount }))

  if (!observations.length) return materialize()

  // Project forward: use the transactions strictly after the last
  // observation that do not have a balance themselves. The transactions with
  // a balance are already observations.
  const pending = txs
    .filter(
      tx =>
        txBalance(tx) == null &&
        txAmount(tx) != null &&
        !!tx.occurred_at &&
        tx.occurred_at > lastObservedAt
    )
    .sort((a, b) => a.occurred_at!.localeCompare(b.occurred_at!))

  if (pending.length) {
    const points = materialize()
    let value = points[points.length - 1].amount
    for (const tx of pending) {
      value += txAmount(tx)!
      byDay.set(utcToZonedParts(tx.occurred_at!).date, value)
    }
  }

  return materialize()
}

export function rateFor(
  currency: string,
  ref: string,
  rates: Rates
): number | null {
  if (currency === ref) return 1
  const r = rates[currency]
  return typeof r === 'number' && Number.isFinite(r) && r > 0 ? r : null
}

// Sums forward-filled curves. There is one point for each date where a curve
// changes. Each curve holds its last value (0 before its first point).
export function sumCurves(curves: SnapshotPoint[][]): SnapshotPoint[] {
  const dates = [
    ...new Set(curves.flatMap(curve => curve.map(point => point.date)))
  ].sort()
  return dates.map(date => ({
    date,
    amount: curves.reduce((sum, curve) => sum + valueAt(curve, date), 0)
  }))
}

// Display adjustment for the overview only. Scale a curve (crypto tax
// haircut, as if the whole value were taxable gain). Then shift it by a flat
// amount (a fixed tax provision owed). Stored balances do not change.
export function adjustCurve(
  points: SnapshotPoint[],
  scale: number,
  shift: number
): SnapshotPoint[] {
  if (scale === 1 && shift === 0) return points
  return points.map(point => ({
    date: point.date,
    amount: point.amount * scale + shift
  }))
}

// Returns the forward-filled total across accounts, in the reference
// currency. There is one point for each date where an account changes. The
// function excludes (and reports) the accounts whose currency has no rate.
// It does not silently count them at zero.
export function universeCurve(
  accounts: Account[],
  seriesByKey: Map<string, SnapshotPoint[]>,
  rates: Rates,
  ref: string
): { points: SnapshotPoint[]; excluded: string[] } {
  const usable: { series: SnapshotPoint[]; rate: number }[] = []
  const excluded: string[] = []

  for (const a of accounts) {
    const series = seriesByKey.get(a.key) || []
    if (!series.length) continue
    const rate = rateFor(a.currency, ref, rates)
    if (rate == null) excluded.push(a.name)
    else usable.push({ series, rate })
  }

  const scaled = usable.map(({ series, rate }) =>
    series.map(point => ({ date: point.date, amount: point.amount * rate }))
  )
  return { points: sumCurves(scaled), excluded }
}

// Portfolio value snapshots: balance entries that have data.universe
// ('crypto') instead of an account_id. Each one is a dated observation of
// the value of the whole portfolio, in its own currency. There is one point
// for each day: the latest observation of the day wins. The function
// excludes and reports the snapshots whose currency has no rate to `ref`,
// the same rule as for accounts.
export function portfolioSeries(
  balanceEntries: Entry[],
  rates: Rates,
  ref: string
): { points: SnapshotPoint[]; excluded: string[] } {
  const observations: { at: string; date: string; amount: number }[] = []
  const excluded: string[] = []

  for (const snapshot of balanceEntries) {
    if (snapshot.data.universe !== 'crypto') continue
    const amount = snapshot.data.amount
    if (typeof amount !== 'number' || !Number.isFinite(amount)) continue
    if (!snapshot.occurred_at) continue
    const date = utcToZonedParts(snapshot.occurred_at).date
    const currency = ((snapshot.data.currency as string) || ref)
      .trim()
      .toUpperCase()
    const rate = rateFor(currency, ref, rates)
    if (rate == null) {
      excluded.push(`${date} (${currency})`)
      continue
    }
    observations.push({
      at: snapshot.occurred_at,
      date,
      amount: amount * rate
    })
  }

  observations.sort((a, b) => a.at.localeCompare(b.at))
  const byDay = new Map<string, number>()
  for (const observation of observations)
    byDay.set(observation.date, observation.amount)

  return {
    points: [...byDay.entries()]
      .sort((a, b) => a[0].localeCompare(b[0]))
      .map(([date, amount]) => ({ date, amount })),
    excluded
  }
}

// The crypto universe curve. When portfolio snapshots exist, they are the
// curve. An observed value beats a derivation, even when no rate can convert
// the snapshots at this time. The quantity-times-manual-rate derivation is
// only for users who never made a snapshot.
export function cryptoCurve(
  cryptoAccounts: Account[],
  seriesByKey: Map<string, SnapshotPoint[]>,
  balanceEntries: Entry[],
  rates: Rates,
  ref: string
): { points: SnapshotPoint[]; excluded: string[] } {
  const portfolio = portfolioSeries(balanceEntries, rates, ref)
  if (portfolio.points.length || portfolio.excluded.length) return portfolio
  return universeCurve(cryptoAccounts, seriesByKey, rates, ref)
}

export interface CryptoTotal {
  total: number
  excluded: string[]
  approx: boolean
  counted: number
}

// Returns the live value of the crypto holdings in the reference currency.
// The spot price comes first (that is what "worth right now" means), and the
// manual rate is the fallback. The function excludes and names an account
// that has neither. `approx` flags any spot component. `counted` tells how
// many accounts are in the sum.
export function cryptoSpotTotal(
  accounts: Account[],
  seriesByKey: Map<string, SnapshotPoint[]>,
  spotPrices: Record<string, number>,
  rates: Rates,
  ref: string
): CryptoTotal {
  let total = 0
  let approx = false
  let counted = 0
  const excluded: string[] = []

  for (const account of accounts) {
    const series = seriesByKey.get(account.key) || []
    if (!series.length) continue
    const quantity = series[series.length - 1].amount
    const spot = spotPrices[account.currency]
    if (typeof spot === 'number' && Number.isFinite(spot)) {
      total += quantity * spot
      approx = true
      counted += 1
      continue
    }
    const rate = rateFor(account.currency, ref, rates)
    if (rate == null) excluded.push(account.name)
    else {
      total += quantity * rate
      counted += 1
    }
  }

  return { total, excluded, approx, counted }
}

// Returns the value of a forward-filled curve at a date (0 before the first
// point).
export function valueAt(points: SnapshotPoint[], date: string): number {
  let value = 0
  for (const p of points) {
    if (p.date > date) break
    value = p.amount
  }
  return value
}

export function daysBetween(from: string, to: string): number {
  const [fy, fm, fd] = from.split('-').map(Number)
  const [ty, tm, td] = to.split('-').map(Number)
  const ms = Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)
  return Math.round(ms / 86_400_000)
}

export function freshnessDays(
  series: SnapshotPoint[],
  today: string
): number | null {
  if (!series.length) return null
  return daysBetween(series[series.length - 1].date, today)
}

// A balance that you can trust is a recent one. Staleness is first-class
// information.
export function freshnessLevel(days: number | null): 'ok' | 'warn' | 'stale' {
  if (days == null) return 'stale'
  if (days <= 35) return 'ok'
  if (days <= 90) return 'warn'
  return 'stale'
}

export const UNCATEGORIZED = 'uncategorized'

export interface SpendingRow {
  category: string
  byMonth: Record<string, number> // month "YYYY-MM" -> spent, in ref currency
  total: number
}

// Returns the normalized tx-account names of the shared accounts, for
// monthlySpending.
export function sharedTxNames(accounts: Account[]): Set<string> {
  const out = new Set<string>()
  for (const a of accounts) if (a.shared) out.add(norm(accountTxName(a)))
  return out
}

// Returns the monthly spending by category, in the reference currency. Only
// outgoing amounts count (amount < 0, stored positive here). The function
// skips the transactions in a currency with no known rate and returns them
// in `excluded`. Transactions of a shared account count half.
export function monthlySpending(
  txs: Entry[],
  rates: Rates,
  ref: string,
  shared: Set<string> = new Set()
): { months: string[]; rows: SpendingRow[]; excluded: Entry[] } {
  const monthSet = new Set<string>()
  const byCategory = new Map<string, Map<string, number>>()
  const excluded: Entry[] = []

  for (const tx of txs) {
    const amount = txAmount(tx)
    if (amount == null || amount >= 0 || !tx.occurred_at) continue
    const currency = ((tx.data.currency as string) || ref).trim().toUpperCase()
    const rate = rateFor(currency, ref, rates)
    if (rate == null) {
      excluded.push(tx)
      continue
    }
    const month = utcToZonedParts(tx.occurred_at).date.slice(0, 7)
    const category =
      ((tx.data.category as string) || '').trim() || UNCATEGORIZED
    const factor = shared.has(norm(txAccountName(tx))) ? 0.5 : 1
    monthSet.add(month)
    const row = byCategory.get(category) || new Map<string, number>()
    row.set(month, (row.get(month) || 0) + -amount * rate * factor)
    byCategory.set(category, row)
  }

  const months = [...monthSet].sort()
  const rows = [...byCategory.entries()]
    .map(([category, m]) => ({
      category,
      byMonth: Object.fromEntries(m),
      total: [...m.values()].reduce((sum, v) => sum + v, 0)
    }))
    .sort((a, b) => b.total - a.total)

  return { months, rows, excluded }
}

// Deterministic tint for each category (same trick as contact avatars).
// The uncategorized bucket stays gray.
export function categoryColor(category: string): string {
  if (category === UNCATEGORIZED) return 'hsl(0, 0%, 55%)'
  let h = 0
  for (let i = 0; i < category.length; i++)
    h = (h * 31 + category.charCodeAt(i)) % 360
  return `hsl(${h}, 55%, 55%)`
}

// Compact money formatting. Large fiat amounts are easier to read without
// cents. Small crypto quantities (0.052 BTC) must keep their decimals.
// `maxDigits` pins the precision when the caller knows better, for example
// in a table of totals where cents are noise.
export function formatAmount(
  amount: number,
  currency: string,
  opts: { maxDigits?: number } = {}
): string {
  const abs = Math.abs(amount)
  const digits = opts.maxDigits ?? (abs >= 1000 ? 0 : abs < 1 ? 6 : 2)
  const formatted = amount.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits
  })
  return `${formatted} ${currency}`
}
