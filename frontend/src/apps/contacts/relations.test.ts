import { describe, it, expect } from 'vitest'

import {
  RELATION_TYPES,
  inverseType,
  normalizeRelationType,
  relationLabel,
  normalizeTags,
  tagsOf,
  relationsOf,
  withRelation,
  withoutRelation
} from './relations'
import type { Entry } from '../types'

function entry(data: Record<string, unknown>): Entry {
  return { id: 'e1', data } as unknown as Entry
}

describe('inverseType', () => {
  it('flips the parent/child pair', () => {
    expect(inverseType('parent')).toBe('child')
    expect(inverseType('child')).toBe('parent')
  })

  it('is identity for symmetric types, custom ones included', () => {
    expect(inverseType('partner')).toBe('partner')
    expect(inverseType('sibling')).toBe('sibling')
    expect(inverseType('friend')).toBe('friend')
    expect(inverseType('colleague')).toBe('colleague')
    expect(inverseType('climbing partner')).toBe('climbing partner')
  })
})

describe('normalizeRelationType', () => {
  it('trims, lowercases and collapses whitespace', () => {
    expect(normalizeRelationType('  Climbing   Partner ')).toBe(
      'climbing partner'
    )
    expect(normalizeRelationType('   ')).toBe('')
  })

  it('caps the length so a pasted paragraph cannot become a type', () => {
    expect(normalizeRelationType('x'.repeat(50))).toHaveLength(30)
  })
})

describe('relationLabel', () => {
  it('capitalizes the slug', () => {
    expect(relationLabel('friend')).toBe('Friend')
  })
})

describe('normalizeTags', () => {
  it('trims, lowercases, dedups and drops empties', () => {
    expect(normalizeTags([' Famille ', 'famille', 'LYON', '  '])).toEqual([
      'famille',
      'lyon'
    ])
  })

  it('rejects non-arrays and non-string items', () => {
    expect(normalizeTags('famille')).toEqual([])
    expect(normalizeTags(undefined)).toEqual([])
    expect(normalizeTags([42, null, 'ok'])).toEqual(['ok'])
  })
})

describe('tagsOf / relationsOf', () => {
  it('read defensively from entry data', () => {
    expect(tagsOf(entry({}))).toEqual([])
    expect(tagsOf(entry({ tags: ['A'] }))).toEqual(['a'])
    expect(relationsOf(entry({}))).toEqual([])
    expect(relationsOf(entry({ relations: 'x' }))).toEqual([])
  })

  it('keeps well-formed relations, custom types included', () => {
    const rels = relationsOf(
      entry({
        relations: [
          { contact_id: 'a', type: 'friend' },
          { contact_id: 42, type: 'friend' },
          { contact_id: 'b', type: 'boss' },
          { contact_id: 'c', type: '  ' },
          { contact_id: 'd', type: 7 },
          null
        ]
      })
    )
    expect(rels).toEqual([
      { contact_id: 'a', type: 'friend' },
      { contact_id: 'b', type: 'boss' }
    ])
  })

  it('dedupes duplicate contact_ids, last wins', () => {
    const rels = relationsOf(
      entry({
        relations: [
          { contact_id: 'a', type: 'friend' },
          { contact_id: 'a', type: 'parent' }
        ]
      })
    )
    expect(rels).toEqual([{ contact_id: 'a', type: 'parent' }])
  })
})

describe('withRelation / withoutRelation', () => {
  it('adds a relation', () => {
    expect(withRelation([], 'a', 'friend')).toEqual([
      { contact_id: 'a', type: 'friend' }
    ])
  })

  it('replaces the type of an existing relation to the same contact', () => {
    const cur = [
      { contact_id: 'a', type: 'friend' },
      { contact_id: 'b', type: 'parent' }
    ] as const
    expect(withRelation([...cur], 'a', 'colleague')).toEqual([
      { contact_id: 'b', type: 'parent' },
      { contact_id: 'a', type: 'colleague' }
    ])
  })

  it('removes only the matching relation', () => {
    const cur = [
      { contact_id: 'a', type: 'friend' },
      { contact_id: 'b', type: 'parent' }
    ] as const
    expect(withoutRelation([...cur], 'a')).toEqual([
      { contact_id: 'b', type: 'parent' }
    ])
    expect(withoutRelation([...cur], 'zz')).toEqual([...cur])
  })
})

describe('RELATION_TYPES', () => {
  it('is the fixed vocabulary', () => {
    expect([...RELATION_TYPES]).toEqual([
      'partner',
      'parent',
      'child',
      'sibling',
      'friend',
      'colleague'
    ])
  })
})
