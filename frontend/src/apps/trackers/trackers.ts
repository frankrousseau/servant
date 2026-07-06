import type { Entry } from '../types'
import { addDays } from '../calendar/recurrence'
import { utcToZonedParts } from '../../lib/datetime'

// Pure logic for manual trackers. A tracker is an entry (kind tracker);
// each day's observation is a tracker_log entry (one per tracker per day,
// upserted). Three natures:
//   check: did it happen (guitar practice), value 0/1
//   count: how many (alcohol doses), incremented through the day
//   value: a measured number (weight, minutes), set rather than incremented

export type TrackerType = 'check' | 'count' | 'value'

export const TRACKER_TYPES: { value: TrackerType; label: string }[] = [
  { value: 'check', label: 'Did it (yes/no)' },
  { value: 'count', label: 'Counter (+1 per unit)' },
  { value: 'value', label: 'Measure (typed value)' }
]

export interface Tracker {
  id: string
  name: string
  type: TrackerType
  unit: string
  color: string
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
  return {
    id: e.id,
    name,
    type: type === 'count' || type === 'value' ? type : 'check',
    unit: ((e.data.unit as string) || '').trim(),
    color: trackerColor(name, e.data.color as string | undefined)
  }
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

export interface HeatCell {
  date: string
  value: number
  // 0 = nothing, 1..4 = intensity (scaled to the window's max for counters)
  level: number
}

// Monday-first column per week, `weeks` columns ending with the current
// week; days after today are null (not yet lived).
export function heatmapWeeks(
  byDate: Map<string, number>,
  today: string,
  type: TrackerType,
  weeks: number
): (HeatCell | null)[][] {
  const dow = (d: string) => {
    const [y, m, day] = d.split('-').map(Number)
    return (new Date(Date.UTC(y, m - 1, day)).getUTCDay() + 6) % 7 // Mon=0
  }
  const monday = addDays(today, -dow(today))
  const start = addDays(monday, -7 * (weeks - 1))

  let max = 0
  for (const [d, v] of byDate) {
    if (d >= start && d <= today && v > max) max = v
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
