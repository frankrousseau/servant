import { describe, it, expect } from 'vitest'
import {
  BUILTIN_APPS,
  DEFAULT_ENABLED_APPS,
  enabledBuiltins,
  agentsEnabled
} from './registry'

describe('enabledBuiltins', () => {
  it('falls back to the default set when the preference is unset', () => {
    expect(enabledBuiltins(null).map(a => a.id)).toEqual(DEFAULT_ENABLED_APPS)
    expect(enabledBuiltins(undefined).map(a => a.id)).toEqual(
      DEFAULT_ENABLED_APPS
    )
  })

  it('filters to the chosen apps, ignoring unknown ids', () => {
    const ids = enabledBuiltins(['notes', 'calendar', 'bogus']).map(a => a.id)
    expect(ids).toEqual(['calendar', 'notes'])
  })

  it('returns nothing when everything is disabled', () => {
    expect(enabledBuiltins([])).toEqual([])
  })

  it('defaults are valid builtin ids', () => {
    const all = BUILTIN_APPS.map(a => a.id)
    for (const id of DEFAULT_ENABLED_APPS) expect(all).toContain(id)
  })
})

describe('agentsEnabled', () => {
  it('is off by default (unset preference)', () => {
    expect(agentsEnabled(null)).toBe(false)
    expect(agentsEnabled(undefined)).toBe(false)
  })

  it('follows the enabled list', () => {
    expect(agentsEnabled(['agents'])).toBe(true)
    expect(agentsEnabled(['notes'])).toBe(false)
  })
})
