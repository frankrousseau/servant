import { describe, it, expect } from 'vitest'

import { buildScopes, scopeFor } from './apiTokenScopes'

describe('apiTokenScopes', () => {
  it('formats app and data scopes', () => {
    expect(scopeFor('notes', 'write')).toBe('app:notes:write')
    expect(scopeFor('data', 'read')).toBe('data:read')
    expect(scopeFor('finance', 'none')).toBeNull()
  })

  it('builds the scope list from form levels', () => {
    expect(buildScopes({ trackers: 'write', finance: 'read' })).toEqual([
      'app:finance:read',
      'app:trackers:write'
    ])
    expect(buildScopes({})).toEqual([])
  })

  it('appends the read-binary opt-in only when asked', () => {
    expect(buildScopes({ photos: 'read' }, true)).toEqual([
      'app:photos:read',
      'data:read-binary'
    ])
    expect(buildScopes({ photos: 'read' })).toEqual(['app:photos:read'])
  })
})
