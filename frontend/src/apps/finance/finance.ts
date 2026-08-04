import type { Entry } from '../types'
import { utcToZonedParts } from '../../lib/datetime'

// Pure logic for the Finance app. Core principle: a balance is an
// observation (snapshot), never a derivation from transactions. Bank CSV
// imports already carry a balance-after-transaction, so bank accounts get
// their history for free; everything else is snapshotted by hand.

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
  // Account name carried by imported transactions (data.account); lets an
  // entity claim transactions when its display name differs from the CSV's.
  identifier: string | null
  // Shared with someone else: spending counts half. Balances stay whole,
  // they are real observations of the real account.
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

// 1 unit of a currency in reference-currency units. The reference itself is
// always 1 and never stored.
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

// The name an account matches transactions on.
export const accountTxName = (a: Account) => a.identifier || a.name

export function accountTxs(account: Account, bankTxs: Entry[]): Entry[] {
  const key = norm(accountTxName(account))
  return bankTxs.filter(tx => norm(txAccountName(tx)) === key)
}

// Entity-backed accounts (kind "account") plus accounts derived from
// bank_tx data.account (same pattern as synced calendar agendas). An entity
// whose name matches a CSV account claims it: the entity absorbs the
// transaction-derived history and can also take manual snapshots.
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

// Snapshot series for one account, one point per day (the latest observation
// of the day wins), sorted ascending. Sources: manual balance entries
// (data.account_id) and, for the matching bank account name (the account's
// identifier, or its name), the balance-after-transaction carried by bank_tx
// imports. Past the last observation the series is projected forward by
// applying subsequent transaction amounts, so the current value stays live
// between snapshots.
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

  // Project forward: transactions strictly after the last observation, that
  // don't carry a balance themselves (those already are observations).
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

// Sum forward-filled curves: one point per date where any curve changes,
// each curve holding its last value (0 before its first point).
export function sumCurves(curves: SnapshotPoint[][]): SnapshotPoint[] {
  const dates = [
    ...new Set(curves.flatMap(curve => curve.map(point => point.date)))
  ].sort()
  return dates.map(date => ({
    date,
    amount: curves.reduce((sum, curve) => sum + valueAt(curve, date), 0)
  }))
}

// Forward-filled total across accounts, in the reference currency: one point
// per date where any account changes. Accounts whose currency has no rate
// are excluded (and reported) rather than silently counted at zero.
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

// Value of a forward-filled curve at a date (0 before the first point).
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

// A balance you can trust is a recent one; staleness is first-class info.
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

// Normalized tx-account names of shared accounts, for monthlySpending.
export function sharedTxNames(accounts: Account[]): Set<string> {
  const out = new Set<string>()
  for (const a of accounts) if (a.shared) out.add(norm(accountTxName(a)))
  return out
}

// Monthly spending by category, in the reference currency. Only outgoing
// amounts count (amount < 0, stored positive here). Transactions in a
// currency with no known rate are skipped and returned in `excluded`.
// Transactions of a shared account count half.
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

// Deterministic tint per category (same trick as contact avatars); the
// uncategorized bucket stays gray.
export function categoryColor(category: string): string {
  if (category === UNCATEGORIZED) return 'hsl(0, 0%, 55%)'
  let h = 0
  for (let i = 0; i < category.length; i++)
    h = (h * 31 + category.charCodeAt(i)) % 360
  return `hsl(${h}, 55%, 55%)`
}

// Compact money formatting: big fiat amounts read better without cents,
// small crypto quantities (0.052 BTC) need their decimals. `maxDigits` pins
// the precision when the caller knows better, e.g. a table of totals where
// cents are noise.
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
