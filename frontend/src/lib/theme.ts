// The theme is the data-theme attribute on <html>. The palettes are in
// style.css. The server persists the choice (a user preference, synced across
// devices). localStorage caches it, so the right palette paints before the
// reply of /auth/me arrives.

export const THEMES = [
  { id: 'night', name: 'Night', hint: 'CRT violet on black-blue glass' },
  { id: 'graphite', name: 'Graphite', hint: 'White phosphor, pure grays' },
  { id: 'day', name: 'Daylight', hint: 'Violet ink on cool paper' },
  {
    id: 'cyanotype',
    name: 'Cyanotype',
    hint: 'Prussian blue on blueprint paper'
  },
  { id: 'sepia', name: 'Sepia', hint: 'Amber ink on warm paper' },
  {
    id: 'rosewood',
    name: 'Rosewood',
    hint: 'Dusty indigo and rosewood on warm beige'
  }
] as const

export type ThemeId = (typeof THEMES)[number]['id']

const STORAGE_KEY = 'servant_theme'

function normalize(id: string | null | undefined): ThemeId {
  return THEMES.some(t => t.id === id) ? (id as ThemeId) : 'night'
}

export function applyTheme(id: string | null | undefined) {
  const theme = normalize(id)
  document.documentElement.dataset.theme = theme
  try {
    localStorage.setItem(STORAGE_KEY, theme)
  } catch {
    // Private mode: the theme still applies for this session.
  }
}

export function storedTheme(): ThemeId {
  try {
    return normalize(localStorage.getItem(STORAGE_KEY))
  } catch {
    return 'night'
  }
}
