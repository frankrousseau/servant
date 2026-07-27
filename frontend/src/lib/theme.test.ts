import { describe, it, expect } from 'vitest'
import { THEMES, applyTheme, storedTheme } from './theme'

describe('applyTheme', () => {
  it('sets the data-theme attribute and persists the choice', () => {
    applyTheme('sepia')
    expect(document.documentElement.dataset.theme).toBe('sepia')
    expect(storedTheme()).toBe('sepia')
  })

  it('falls back to night for unknown or missing ids', () => {
    applyTheme('solarized')
    expect(document.documentElement.dataset.theme).toBe('night')
    applyTheme(null)
    expect(document.documentElement.dataset.theme).toBe('night')
  })

  it('exposes six themes with night first', () => {
    expect(THEMES.map(t => t.id)).toEqual([
      'night',
      'graphite',
      'day',
      'cyanotype',
      'sepia',
      'rosewood'
    ])
  })
})
