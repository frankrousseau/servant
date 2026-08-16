import type { Entry } from '../types'
import { addDays } from '../calendar/recurrence'
import { utcToZonedParts } from '../../lib/datetime'

// Pure logic for trackers. A tracker is an entry (kind tracker);
// each day's observation is a tracker_log entry (one per tracker per day,
// upserted). Four natures:
//   check: did it happen (guitar practice), value 0/1
//   count: how many (alcohol doses), incremented through the day
//   value: a measured number (weight, minutes), set rather than incremented
//   entry: computed from existing entries of a kind (commits per day),
//          COUNT or SUM of a data field via /api/entries/aggregate; no logs

export type TrackerType = 'check' | 'count' | 'value' | 'entry'

export const TRACKER_TYPES: { value: TrackerType; label: string }[] = [
  { value: 'check', label: 'Did it (yes/no)' },
  { value: 'count', label: 'Counter (+1 per unit)' },
  { value: 'value', label: 'Measure (typed value)' },
  { value: 'entry', label: 'From existing entries (auto)' }
]

export interface Tracker {
  id: string
  name: string
  type: TrackerType
  unit: string
  color: string
  // entry trackers only
  entryKind?: string
  agg?: 'count' | 'sum'
  field?: string
}

const PALETTE = [
  '#9d7bff',
  '#6ccec9',
  '#4fd674',
  '#ffb454',
  '#ff5c7a',
  '#5ca0ff'
]

// Stable default color per name (djb2), same scheme as calendar agendas;
// an explicit data.color wins.
export function trackerColor(name: string, stored?: string): string {
  if (stored) return stored
  let h = 5381
  for (let i = 0; i < name.length; i++)
    h = ((h << 5) + h + name.charCodeAt(i)) | 0
  return PALETTE[Math.abs(h) % PALETTE.length]
}

export function trackerFromEntry(e: Entry): Tracker {
  const type = e.data.type as TrackerType
  const name = (e.title || 'Unnamed').trim()
  const entryKind = ((e.data.entry_kind as string) || '').trim()
  if (type === 'entry' && entryKind) {
    return {
      id: e.id,
      name,
      type,
      unit: ((e.data.unit as string) || '').trim(),
      color: trackerColor(name, e.data.color as string | undefined),
      entryKind,
      agg: e.data.agg === 'sum' ? 'sum' : 'count',
      field: ((e.data.field as string) || '').trim() || undefined
    }
  }
  return {
    id: e.id,
    name,
    type: type === 'count' || type === 'value' ? type : 'check',
    unit: ((e.data.unit as string) || '').trim(),
    color: trackerColor(name, e.data.color as string | undefined)
  }
}

// date -> value from /api/entries/aggregate day buckets (already in user tz).
export function aggregateByDate(
  rows: { bucket: string; value: number }[]
): Map<string, number> {
  const byDate = new Map<string, number>()
  for (const r of rows) {
    if (typeof r.value === 'number' && Number.isFinite(r.value))
      byDate.set(r.bucket, r.value)
  }
  return byDate
}

// date (user tz) -> value, from that tracker's logs. Later observations of
// the same day win (occurred_at order).
export function logsByDate(
  logs: Entry[],
  trackerId: string
): Map<string, number> {
  const byDate = new Map<string, number>()
  const mine = logs
    .filter(l => l.data.tracker_id === trackerId && l.occurred_at)
    .sort((a, b) => (a.occurred_at || '').localeCompare(b.occurred_at || ''))
  for (const l of mine) {
    const value = l.data.value
    if (typeof value !== 'number' || !Number.isFinite(value)) continue
    byDate.set(utcToZonedParts(l.occurred_at!).date, value)
  }
  return byDate
}

// Consecutive days with a positive value, ending today; a not-yet-logged
// today does not break the streak (the day is not over).
export function streak(byDate: Map<string, number>, today: string): number {
  let day = today
  if (!((byDate.get(day) ?? 0) > 0)) day = addDays(day, -1)
  let n = 0
  while ((byDate.get(day) ?? 0) > 0) {
    n++
    day = addDays(day, -1)
  }
  return n
}

// Sum over the last n days, today included.
export function sumLastDays(
  byDate: Map<string, number>,
  today: string,
  n: number
): number {
  let total = 0
  for (let i = 0; i < n; i++) total += byDate.get(addDays(today, -i)) ?? 0
  return total
}

// Most recent logged value on or before today (for measures).
export function lastValue(
  byDate: Map<string, number>,
  today: string
): number | null {
  const dates = [...byDate.keys()].filter(d => d <= today).sort()
  if (!dates.length) return null
  return byDate.get(dates[dates.length - 1]) ?? null
}

// ----- Period rollups (detail view) -----

export type RollupPeriod = 'week' | 'month' | 'year'

export interface RollupRow {
  // 'YYYY-MM-DD' Monday for weeks, 'YYYY-MM' for months, 'YYYY' for years;
  // same keys as the backend aggregate buckets, lexicographically sortable
  bucket: string
  // per-type semantics: check = days done, count = sum, value = mean
  value: number
  // logged days contributing (0 for zero-filled gap rows)
  days: number
}

export function bucketOf(date: string, period: RollupPeriod): string {
  if (period === 'week') return weekMonday(date)
  if (period === 'month') return date.slice(0, 7)
  return date.slice(0, 4)
}

export function nextBucket(bucket: string, period: RollupPeriod): string {
  if (period === 'week') return addDays(bucket, 7)
  if (period === 'month') {
    const [year, month] = bucket.split('-').map(Number)
    if (month === 12) return `${year + 1}-01`
    return `${year}-${String(month + 1).padStart(2, '0')}`
  }
  return String(Number(bucket) + 1)
}

// Every bucket from the earliest row up to bucketOf(today), gap buckets
// zero-filled so quiet periods stay visible. Sorted ascending.
export function fillBuckets(
  rows: RollupRow[],
  period: RollupPeriod,
  today: string
): RollupRow[] {
  if (!rows.length) return []
  const byBucket = new Map(rows.map(row => [row.bucket, row]))
  const first = [...byBucket.keys()].sort()[0]
  const last = bucketOf(today, period)

  const out: RollupRow[] = []
  for (let bucket = first; bucket <= last; bucket = nextBucket(bucket, period))
    out.push(byBucket.get(bucket) ?? { bucket, value: 0, days: 0 })
  return out
}

// Rolls a tracker's byDate map up into periods. check counts done days,
// count sums, value averages over logged days (a weight logged twice a
// week must not sum). Future-dated logs are excluded, like heatmapWeeks.
export function rollup(
  byDate: Map<string, number>,
  type: TrackerType,
  period: RollupPeriod,
  today: string
): RollupRow[] {
  const sums = new Map<string, { sum: number; done: number; days: number }>()
  for (const [date, value] of byDate) {
    if (date > today) continue
    const bucket = bucketOf(date, period)
    const acc = sums.get(bucket) ?? { sum: 0, done: 0, days: 0 }
    acc.sum += value
    if (value > 0) acc.done++
    acc.days++
    sums.set(bucket, acc)
  }

  const rows = [...sums].map(([bucket, acc]) => ({
    bucket,
    value:
      type === 'check'
        ? acc.done
        : type === 'value'
          ? acc.sum / acc.days
          : acc.sum,
    days: acc.days
  }))

  return fillBuckets(rows, period, today)
}

export interface HeatCell {
  date: string
  value: number
  // 0 = nothing, 1..4 = intensity (scaled to the window's max for counters)
  level: number
}

// Monday of the week containing `date` (Mon-first weeks).
export function weekMonday(date: string): string {
  const [y, m, day] = date.split('-').map(Number)
  const dow = (new Date(Date.UTC(y, m - 1, day)).getUTCDay() + 6) % 7 // Mon=0
  return addDays(date, -dow)
}

// Monday-first column per week, `weeks` columns ending with the week of
// `endDate` (today by default, earlier when browsing the past); days after
// today are null (not yet lived).
export function heatmapWeeks(
  byDate: Map<string, number>,
  today: string,
  type: TrackerType,
  weeks: number,
  endDate = today
): (HeatCell | null)[][] {
  const monday = weekMonday(endDate < today ? endDate : today)
  const start = addDays(monday, -7 * (weeks - 1))
  const last = addDays(monday, 6)

  let max = 0
  for (const [d, v] of byDate) {
    if (d >= start && d <= last && d <= today && v > max) max = v
  }

  const level = (value: number): number => {
    if (value <= 0) return 0
    if (type === 'check') return 4
    return Math.max(1, Math.min(4, Math.ceil((4 * value) / (max || 1))))
  }

  const out: (HeatCell | null)[][] = []
  for (let w = 0; w < weeks; w++) {
    const col: (HeatCell | null)[] = []
    for (let d = 0; d < 7; d++) {
      const date = addDays(start, w * 7 + d)
      if (date > today) {
        col.push(null)
        continue
      }
      const value = byDate.get(date) ?? 0
      col.push({ date, value, level: level(value) })
    }
    out.push(col)
  }
  return out
}
