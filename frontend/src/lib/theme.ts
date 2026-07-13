// Theme = data-theme attribute on <html>, palettes in style.css. The choice
// is persisted server-side (user preference, synced across devices) and
// cached in localStorage so the right palette paints before /auth/me lands.

export const THEMES = [
  { id: 'night', name: 'Night', hint: 'CRT violet on black-blue glass' },
  { id: 'graphite', name: 'Graphite', hint: 'White phosphor, pure grays' },
  { id: 'day', name: 'Daylight', hint: 'Violet ink on cool paper' },
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
    // private mode: the theme still applies for this session
  }
}

export function storedTheme(): ThemeId {
  try {
    return normalize(localStorage.getItem(STORAGE_KEY))
  } catch {
    return 'night'
  }
}
