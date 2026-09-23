import { describe, it, expect } from 'vitest'

import {
  findDuplicateGroups,
  normalizeName,
  normalizePhone,
  suggestedSurvivor
} from './duplicates'

import type { Entry } from '../types'

function contact(
  id: string,
  displayName: string,
  data: Record<string, unknown> = {},
  insertedAt = '2026-01-01T00:00:00Z'
): Entry {
  return {
    id,
    kind: 'contact',
    source: 'manual',
    external_id: null,
    title: displayName,
    occurred_at: null,
    data: { display_name: displayName, ...data },
    metadata: {},
    inserted_at: insertedAt,
    updated_at: insertedAt
  }
}

const labeled = (...values: string[]) =>
  values.map(value => ({ value, type: 'home' }))

describe('normalizers', () => {
  it('folds case, accents and punctuation in names', () => {
    expect(normalizeName('Élodie  Durand-Roux')).toBe('elodie durand roux')
  })

  it('compares phones on their trailing digits', () => {
    expect(normalizePhone('+33 6 12 34 56 78')).toBe('612345678')
    expect(normalizePhone('06 12 34 56 78')).toBe('612345678')
    expect(normalizePhone('12345')).toBe('')
  })
})

describe('findDuplicateGroups', () => {
  it('groups on a shared email, phone or name, and says why', () => {
    const groups = findDuplicateGroups([
      contact('a', 'Alice Martin', { emails: labeled('Alice@x.io') }),
      contact('b', 'A. Martin', { emails: labeled('alice@x.io') }),
      contact('c', 'Bob', { phones: labeled('+33 6 12 34 56 78') }),
      contact('d', 'Robert', { phones: labeled('06 12 34 56 78') }),
      contact('e', 'élodie durand'),
      contact('f', 'Elodie DURAND'),
      contact('g', 'Nobody alike')
    ])

    expect(
      groups.map(group => [
        group.contacts.map(entry => entry.id),
        group.reasons
      ])
    ).toEqual([
      [['a', 'b'], ['email']],
      [['c', 'd'], ['phone']],
      [['e', 'f'], ['name']]
    ])
  })

  it('chains matches into one group with every reason', () => {
    const groups = findDuplicateGroups([
      contact('a', 'Alice', { emails: labeled('alice@x.io') }),
      contact('b', 'Alice B', { emails: labeled('alice@x.io') }),
      contact('c', 'Alice B')
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0].contacts.map(entry => entry.id)).toEqual(['a', 'b', 'c'])
    expect(groups[0].reasons).toEqual(['email', 'name'])
  })

  it('ignores unnamed contacts and blank values', () => {
    const groups = findDuplicateGroups([
      contact('a', '', { emails: labeled('') }),
      contact('b', '', { phones: labeled('') })
    ])
    expect(groups).toEqual([])
  })
})

describe('suggestedSurvivor', () => {
  it('prefers the fuller card, then the older one', () => {
    const thin = contact('thin', 'Alice', {}, '2026-01-01T00:00:00Z')
    const full = contact(
      'full',
      'Alice',
      { org: 'ACME', photo: '/files/a.jpg' },
      '2026-05-01T00:00:00Z'
    )
    const older = contact('older', 'Alice', {}, '2025-01-01T00:00:00Z')
    expect(
      suggestedSurvivor({ contacts: [thin, full, older], reasons: ['name'] }).id
    ).toBe('full')
    expect(
      suggestedSurvivor({ contacts: [thin, older], reasons: ['name'] }).id
    ).toBe('older')
  })
})
