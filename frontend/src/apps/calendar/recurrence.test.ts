import { describe, it, expect } from 'vitest'

import { nextOccurrence, occursOn, recurrenceOf } from './recurrence'

describe('recurrenceOf', () => {
  it('accepts only known values', () => {
    expect(recurrenceOf({ recurrence: 'yearly' })).toBe('yearly')
    expect(recurrenceOf({ recurrence: 'sometimes' })).toBeNull()
    expect(recurrenceOf({})).toBeNull()
  })
})

describe('occursOn', () => {
  it('never occurs before the seed', () => {
    expect(occursOn('2026-03-12', 'yearly', '2025-03-12')).toBe(false)
    expect(occursOn('2026-03-12', 'yearly', '2026-03-12')).toBe(true)
  })

  it('yearly matches the anniversary date (birthdays)', () => {
    expect(occursOn('1985-03-12', 'yearly', '2026-03-12')).toBe(true)
    expect(occursOn('1985-03-12', 'yearly', '2026-03-13')).toBe(false)
    expect(occursOn('1985-03-12', 'yearly', '2026-04-12')).toBe(false)
  })

  it('clamps Feb 29 anniversaries to Feb 28 in non-leap years', () => {
    expect(occursOn('2024-02-29', 'yearly', '2026-02-28')).toBe(true)
    expect(occursOn('2024-02-29', 'yearly', '2026-03-01')).toBe(false)
    expect(occursOn('2024-02-29', 'yearly', '2028-02-29')).toBe(true)
    expect(occursOn('2024-02-29', 'yearly', '2028-02-28')).toBe(false)
  })

  it('weekly matches the same weekday', () => {
    // 2026-07-06 is a Monday
    expect(occursOn('2026-07-06', 'weekly', '2026-07-13')).toBe(true)
    expect(occursOn('2026-07-06', 'weekly', '2026-07-14')).toBe(false)
  })

  it('monthly matches the day of month, clamped to shorter months', () => {
    expect(occursOn('2026-01-15', 'monthly', '2026-02-15')).toBe(true)
    expect(occursOn('2026-01-15', 'monthly', '2026-02-16')).toBe(false)
    expect(occursOn('2026-01-31', 'monthly', '2026-04-30')).toBe(true)
    expect(occursOn('2026-01-31', 'monthly', '2026-04-29')).toBe(false)
  })
})

describe('nextOccurrence', () => {
  it('returns the seed itself when it is still ahead', () => {
    expect(nextOccurrence('2026-09-01', 'yearly', '2026-07-06')).toBe(
      '2026-09-01'
    )
  })

  it('finds the next anniversary from a date after the seed', () => {
    expect(nextOccurrence('1985-03-12', 'yearly', '2026-07-06')).toBe(
      '2027-03-12'
    )
    expect(nextOccurrence('1985-03-12', 'yearly', '2026-03-12')).toBe(
      '2026-03-12'
    )
  })

  it('finds the next weekly and monthly occurrences', () => {
    expect(nextOccurrence('2026-07-06', 'weekly', '2026-07-08')).toBe(
      '2026-07-13'
    )
    expect(nextOccurrence('2026-01-31', 'monthly', '2026-04-01')).toBe(
      '2026-04-30'
    )
  })
})
