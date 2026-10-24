import { describe, expect, it } from 'vitest'

import { kindLabel } from './kind'

describe('kindLabel', () => {
  it('names the kinds whose id is not a word', () => {
    expect(kindLabel('bank_tx')).toBe('Bank transactions')
    expect(kindLabel('activity')).toBe('Activities')
  })

  it('pluralizes and capitalizes any other kind', () => {
    expect(kindLabel('article')).toBe('Articles')
    expect(kindLabel('tracker_log')).toBe('Tracker logs')
  })
})
