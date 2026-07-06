// Shared vCard/contact helpers, so the contacts app, contact detail view and
// photo people-tagging can't drift on how a name is derived or cleaned.
import type { Entry } from '../types'

// A trimmed contact field with leading/trailing vCard `;` separators stripped.
export function contactField(entry: Entry, key: string): string {
  const val = (entry.data?.[key] as string) || ''
  return val
    .trim()
    .replace(/^;+|;+$/g, '')
    .trim()
}

// Strips surrounding quote characters (straight, curly, guillemets).
export function cleanName(raw: string): string {
  return raw.replace(/^["'«»“”‘’]+|["'«»“”‘’]+$/g, '').trim()
}

// Display name: the vCard display_name, else the first title segment
// ("Name - org - email"; entries created before July 2026 used " — "),
// else "(unnamed)".
export function contactName(c: Entry): string {
  const name =
    contactField(c, 'display_name') || c.title?.split(/ - | — /)[0] || ''
  return cleanName(name) || '(unnamed)'
}

// Up to two uppercase initials from a name.
export function contactInitials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map(w => w[0]?.toUpperCase() || '')
    .join('')
}

// A contact's raw birthday (vCard BDAY: "1990-01-15", "19900115", or the
// year-less "--01-15"/"--0115") as a civil "YYYY-MM-DD" seed for yearly
// recurrence. Unknown years map to 1900 (the seed only anchors month/day).
// Returns null when unparseable.
export function birthdaySeed(raw: string): string | null {
  const s = raw.trim()
  const m =
    /^(\d{4})-(\d{2})-(\d{2})/.exec(s) ||
    /^(\d{4})(\d{2})(\d{2})$/.exec(s) ||
    /^--(\d{2})-?(\d{2})$/.exec(s)
  if (!m) return null
  const [y, mo, d] = m.length === 4 ? [m[1], m[2], m[3]] : ['1900', m[1], m[2]]
  const month = Number(mo)
  const day = Number(d)
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return `${y}-${mo}-${d}`
}

// True when the seed's year is real (not the unknown-year 1900 placeholder).
export function birthdayYearKnown(seed: string): boolean {
  return !seed.startsWith('1900-')
}
