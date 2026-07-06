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
    out.push({
      key: e.id,
      entryId: e.id,
      name: (e.title || 'Unnamed').trim(),
      type,
      currency: ((e.data.currency as string) || 'EUR').trim().toUpperCase(),
      universe: universeOf(type),
      derived: false
    })
    claimed.add(norm(e.title || ''))
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
// (data.account_id) and, for the matching bank account name, the
// balance-after-transaction carried by bank_tx imports.
export function snapshotSeries(
  account: Account,
  balanceEntries: Entry[],
  bankTxs: Entry[]
): SnapshotPoint[] {
  const observations: { at: string; date: string; amount: number }[] = []

  for (const tx of bankTxs) {
    if (norm(txAccountName(tx)) !== norm(account.name)) continue
    const balance = txBalance(tx)
    if (balance == null || !tx.occurred_at) continue
    observations.push({
      at: tx.occurred_at,
      date: utcToZonedParts(tx.occurred_at).date,
      amount: balance
    })
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
    }
  }

  observations.sort((a, b) => a.at.localeCompare(b.at))
  const byDay = new Map<string, number>()
  for (const o of observations) byDay.set(o.date, o.amount)

  return [...byDay.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([date, amount]) => ({ date, amount }))
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

  const dates = [
    ...new Set(usable.flatMap(u => u.series.map(p => p.date)))
  ].sort()

  const points = dates.map(date => {
    let total = 0
    for (const { series, rate } of usable) {
      // Last observation on or before the date; nothing yet counts as 0.
      let value = 0
      for (const p of series) {
        if (p.date > date) break
        value = p.amount
      }
      total += value * rate
    }
    return { date, amount: total }
  })

  return { points, excluded }
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

// Compact money formatting: big fiat amounts read better without cents,
// small crypto quantities (0.052 BTC) need their decimals.
export function formatAmount(amount: number, currency: string): string {
  const abs = Math.abs(amount)
  const digits = abs >= 1000 ? 0 : abs < 1 ? 6 : 2
  const formatted = amount.toLocaleString(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits
  })
  return `${formatted} ${currency}`
}
