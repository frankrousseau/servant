import { describe, it, expect, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import { formatDate, formatDateTime, formatTime } from './datetime'
import { useAuthStore } from '../stores/auth'

import type { User } from '../types'

// 2026-12-31 14:30 UTC. The tests read it in a fixed zone, so the assertions
// are true in all the places where the suite runs.
const ISO = '2026-12-31T14:30:00Z'

function asUser(prefs: Partial<User>) {
  useAuthStore().user = {
    id: 'u1',
    username: 'frank',
    display_name: 'Frank',
    email: null,
    avatar_path: null,
    timezone: 'UTC',
    ...prefs
  } as User
}

describe('display preferences', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders the date in the chosen order', () => {
    asUser({ date_format: 'dmy' })
    expect(formatDate(ISO)).toBe('31/12/2026')
    asUser({ date_format: 'mdy' })
    expect(formatDate(ISO)).toBe('12/31/2026')
    asUser({ date_format: 'iso' })
    expect(formatDate(ISO)).toBe('2026-12-31')
  })

  it('renders the date in the user timezone, not UTC', () => {
    asUser({ date_format: 'iso', timezone: 'Pacific/Auckland' })
    // 14:30 UTC on the 31st is already the 1st in Auckland (+13).
    expect(formatDate(ISO)).toBe('2027-01-01')
  })

  it('picks the hour cycle', () => {
    asUser({ time_format: '24h' })
    expect(formatTime(ISO)).toBe('14:30')
    asUser({ time_format: '12h' })
    expect(formatTime(ISO)).toMatch(/2:30\s*PM/i)
  })

  it('combines both in formatDateTime', () => {
    asUser({ date_format: 'iso', time_format: '24h' })
    expect(formatDateTime(ISO)).toBe('2026-12-31 14:30')
  })

  // A caller that asks for a shape wants that shape. A global setting must
  // not change a label that is compact on purpose.
  it('leaves explicit options alone', () => {
    asUser({ date_format: 'iso' })
    // The result is the month name and the day, in the locale of the runner
    // ("Dec 31", "31 déc."). The important point is that the preference did
    // not force 2026-12-31.
    const compact = formatDate(ISO, { month: 'short', day: 'numeric' })
    expect(compact).toContain('31')
    expect(compact).not.toContain('2026')
  })

  it('falls back to the browser when nothing is set', () => {
    asUser({})
    // For all runner locales, the medium date style is not one of the three
    // explicit orders.
    expect(formatDate(ISO)).not.toBe('2026-12-31')
    expect(formatDate(ISO)).not.toBe('')
  })
})
