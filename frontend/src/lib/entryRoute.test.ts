import { describe, it, expect } from 'vitest'

import { entryRoute } from './entryRoute'
import type { Entry } from '../types'

function entry(kind: string): Entry {
  return {
    id: '42',
    kind,
    source: 'manual',
    external_id: null,
    title: 'x',
    occurred_at: null,
    data: {},
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('entryRoute', () => {
  it('routes each kind to its surface', () => {
    expect(entryRoute(entry('note'))).toBe('/apps/notes?selected=42')
    expect(entryRoute(entry('checklist'))).toBe('/apps/checklists?selected=42')
    expect(entryRoute(entry('event'))).toBe('/apps/calendar')
    expect(entryRoute(entry('contact'))).toBe('/contacts/42')
    expect(entryRoute(entry('photo'))).toBe('/photos/42')
    expect(entryRoute(entry('file'))).toBe('/apps/files')
    expect(entryRoute(entry('invoice'))).toBe('/apps/files')
  })

  it('routes finance kinds to the finance app', () => {
    expect(entryRoute(entry('account'))).toBe('/apps/finance')
    expect(entryRoute(entry('balance'))).toBe('/apps/finance')
    expect(entryRoute(entry('bank_tx'))).toBe('/apps/finance')
  })

  it('falls back to the data browser', () => {
    expect(entryRoute(entry('transaction'))).toBe('/data?entry=42')
  })
})
