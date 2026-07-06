import { describe, it, expect } from 'vitest'
import {
  contactField,
  cleanName,
  contactName,
  contactInitials,
  birthdaySeed,
  birthdayYearKnown
} from './contact'
import type { Entry } from '../types'

function entry(
  data: Record<string, unknown>,
  title: string | null = null
): Entry {
  return {
    id: '1',
    kind: 'contact',
    source: 'vcard',
    external_id: null,
    title,
    occurred_at: null,
    data,
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('contactField', () => {
  it('trims and strips leading/trailing vCard semicolons', () => {
    expect(contactField(entry({ n: ';;Doe;;' }), 'n')).toBe('Doe')
    expect(contactField(entry({}), 'missing')).toBe('')
  })
})

describe('cleanName', () => {
  it('strips surrounding quotes', () => {
    expect(cleanName('"Jane"')).toBe('Jane')
    expect(cleanName('«Jean»')).toBe('Jean')
    expect(cleanName('“Bob”')).toBe('Bob')
  })
})

describe('contactName', () => {
  it('prefers display_name', () => {
    expect(
      contactName(entry({ display_name: 'Jane Doe' }, 'Jane - ACME'))
    ).toBe('Jane Doe')
  })

  it('falls back to the first title segment', () => {
    expect(contactName(entry({}, 'Jane Doe - ACME - jane@acme.com'))).toBe(
      'Jane Doe'
    )
  })

  it('still parses legacy em dash titles (pre-July 2026 entries)', () => {
    expect(contactName(entry({}, 'Jane Doe — ACME — jane@acme.com'))).toBe(
      'Jane Doe'
    )
  })

  it('returns (unnamed) when nothing is present', () => {
    expect(contactName(entry({}, null))).toBe('(unnamed)')
  })
})

describe('contactInitials', () => {
  it('takes up to two uppercase initials', () => {
    expect(contactInitials('Jane Doe')).toBe('JD')
    expect(contactInitials('madonna')).toBe('M')
    expect(contactInitials('a b c d')).toBe('AB')
  })
})

describe('birthdaySeed', () => {
  it('parses the vCard BDAY formats', () => {
    expect(birthdaySeed('1985-03-12')).toBe('1985-03-12')
    expect(birthdaySeed('1985-03-12T00:00:00')).toBe('1985-03-12')
    expect(birthdaySeed('19850312')).toBe('1985-03-12')
    expect(birthdaySeed('--03-12')).toBe('1900-03-12')
    expect(birthdaySeed('--0312')).toBe('1900-03-12')
  })

  it('rejects garbage and impossible dates', () => {
    expect(birthdaySeed('')).toBeNull()
    expect(birthdaySeed('next tuesday')).toBeNull()
    expect(birthdaySeed('1985-13-40')).toBeNull()
  })

  it('knows whether the year is real', () => {
    expect(birthdayYearKnown('1985-03-12')).toBe(true)
    expect(birthdayYearKnown('1900-03-12')).toBe(false)
  })
})
