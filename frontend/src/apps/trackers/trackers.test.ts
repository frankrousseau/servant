import { describe, it, expect } from 'vitest'

import {
  aggregateByDate,
  heatmapWeeks,
  lastValue,
  logsByDate,
  streak,
  sumLastDays,
  trackerColor,
  trackerFromEntry
} from './trackers'
import type { Entry } from '../types'

function log(trackerId: string, occurredAt: string, value: number): Entry {
  return {
    id: Math.random().toString(36).slice(2),
    kind: 'tracker_log',
    source: 'trackers_app',
    external_id: null,
    title: null,
    occurred_at: occurredAt,
    data: { tracker_id: trackerId, value },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

const asMap = (pairs: [string, number][]) => new Map(pairs)

describe('trackerFromEntry', () => {
  it('normalizes unknown types to check and applies colors', () => {
    const entry = log('x', '2026-01-01T12:00:00Z', 0)
    const tracker = trackerFromEntry({
      ...entry,
      kind: 'tracker',
      title: 'Guitare',
      data: { type: 'bogus', unit: ' min ' }
    })
    expect(tracker.type).toBe('check')
    expect(tracker.unit).toBe('min')
    expect(tracker.color).toBe(trackerColor('Guitare'))
  })

  it('parses entry trackers, defaulting agg to count', () => {
    const entry = log('x', '2026-01-01T12:00:00Z', 0)
    const tracker = trackerFromEntry({
      ...entry,
      kind: 'tracker',
      title: 'Commits',
      data: { type: 'entry', entry_kind: 'commit' }
    })
    expect(tracker.type).toBe('entry')
    expect(tracker.entryKind).toBe('commit')
    expect(tracker.agg).toBe('count')
    expect(tracker.field).toBeUndefined()

    const sum = trackerFromEntry({
      ...entry,
      kind: 'tracker',
      title: 'Distance',
      data: { type: 'entry', entry_kind: 'workout', agg: 'sum', field: 'km' }
    })
    expect(sum.agg).toBe('sum')
    expect(sum.field).toBe('km')
  })

  it('falls back to check when an entry tracker has no kind', () => {
    const entry = log('x', '2026-01-01T12:00:00Z', 0)
    const tracker = trackerFromEntry({
      ...entry,
      kind: 'tracker',
      title: 'Broken',
      data: { type: 'entry' }
    })
    expect(tracker.type).toBe('check')
  })
})

describe('aggregateByDate', () => {
  it('maps day buckets to values, dropping non-numeric ones', () => {
    const map = aggregateByDate([
      { bucket: '2026-07-10', value: 3 },
      { bucket: '2026-07-11', value: 8.5 },
      { bucket: '2026-07-12', value: NaN }
    ])
    expect(map.get('2026-07-10')).toBe(3)
    expect(map.get('2026-07-11')).toBe(8.5)
    expect(map.size).toBe(2)
  })
})

describe('logsByDate', () => {
  it('keys values by user-tz date, later logs win', () => {
    const logs = [
      log('t1', '2026-07-01T08:00:00Z', 1),
      log('t1', '2026-07-01T20:00:00Z', 3),
      log('t1', '2026-07-02T08:00:00Z', 2),
      log('other', '2026-07-01T08:00:00Z', 9)
    ]
    const map = logsByDate(logs, 't1')
    expect(map.get('2026-07-01')).toBe(3)
    expect(map.get('2026-07-02')).toBe(2)
    expect(map.size).toBe(2)
  })
})

describe('streak', () => {
  it('counts consecutive positive days ending today', () => {
    const map = asMap([
      ['2026-07-04', 1],
      ['2026-07-05', 1],
      ['2026-07-06', 1]
    ])
    expect(streak(map, '2026-07-06')).toBe(3)
  })

  it('an unlogged today does not break the streak', () => {
    const map = asMap([
      ['2026-07-04', 1],
      ['2026-07-05', 1]
    ])
    expect(streak(map, '2026-07-06')).toBe(2)
  })

  it('a zero value breaks it', () => {
    const map = asMap([
      ['2026-07-04', 1],
      ['2026-07-05', 0],
      ['2026-07-06', 1]
    ])
    expect(streak(map, '2026-07-06')).toBe(1)
  })
})

describe('sums and last value', () => {
  it('sumLastDays adds the trailing window, today included', () => {
    const map = asMap([
      ['2026-06-29', 5],
      ['2026-07-05', 2],
      ['2026-07-06', 1]
    ])
    expect(sumLastDays(map, '2026-07-06', 7)).toBe(3)
    expect(sumLastDays(map, '2026-07-06', 30)).toBe(8)
  })

  it('lastValue returns the latest measure on or before today', () => {
    const map = asMap([
      ['2026-07-01', 78.5],
      ['2026-07-04', 78.1]
    ])
    expect(lastValue(map, '2026-07-06')).toBe(78.1)
    expect(lastValue(new Map(), '2026-07-06')).toBeNull()
  })
})

describe('heatmapWeeks', () => {
  // 2026-07-06 is a Monday.
  it('builds Monday-first columns with nulls after today', () => {
    const weeks = heatmapWeeks(new Map(), '2026-07-07', 'check', 2)
    expect(weeks).toHaveLength(2)
    expect(weeks[0].every(c => c !== null)).toBe(true)
    expect(weeks[1][0]!.date).toBe('2026-07-06')
    expect(weeks[1][1]!.date).toBe('2026-07-07')
    expect(weeks[1][2]).toBeNull()
  })

  it('check trackers are all-or-nothing, counters scale to the max', () => {
    const map = asMap([
      ['2026-07-06', 1],
      ['2026-07-07', 4]
    ])
    const check = heatmapWeeks(map, '2026-07-07', 'check', 1)
    expect(check[0][0]!.level).toBe(4)
    expect(check[0][1]!.level).toBe(4)

    const count = heatmapWeeks(map, '2026-07-07', 'count', 1)
    expect(count[0][0]!.level).toBe(1)
    expect(count[0][1]!.level).toBe(4)
  })

  it('a past endDate shifts the window back with no future nulls', () => {
    const weeks = heatmapWeeks(
      new Map(),
      '2026-07-07',
      'check',
      2,
      '2026-06-10'
    )
    expect(weeks).toHaveLength(2)
    // Last column is the week of June 10 (Mon June 8), fully lived.
    expect(weeks[1][0]!.date).toBe('2026-06-08')
    expect(weeks[1][6]!.date).toBe('2026-06-14')
    expect(weeks.flat().every(c => c !== null)).toBe(true)
  })

  it('an endDate beyond today is clamped to today', () => {
    const weeks = heatmapWeeks(
      new Map(),
      '2026-07-07',
      'check',
      1,
      '2026-08-01'
    )
    expect(weeks[0][1]!.date).toBe('2026-07-07')
    expect(weeks[0][2]).toBeNull()
  })
})
