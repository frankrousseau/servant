// Shared helpers for vCards and contacts. With them, the contacts app, the
// contact detail view and the tagging of people on photos derive and clean a
// name in the same way.
import type { Entry } from '../types'

// Returns a trimmed contact field, without the vCard `;` separators at its
// start and at its end.
export function contactField(entry: Entry, key: string): string {
  const val = (entry.data?.[key] as string) || ''
  return val
    .trim()
    .replace(/^;+|;+$/g, '')
    .trim()
}

// Strips the quote characters around the name (straight, curly, guillemets).
export function cleanName(raw: string): string {
  return raw.replace(/^["'«»“”‘’]+|["'«»“”‘’]+$/g, '').trim()
}

// Returns the display name: the vCard display_name, or if there is none, the
// first segment of the title ("Name - org - email"). The entries created
// before July 2026 used " — ". The last fallback is "(unnamed)".
export function contactName(c: Entry): string {
  const name =
    contactField(c, 'display_name') || c.title?.split(/ - | — /)[0] || ''
  return cleanName(name) || '(unnamed)'
}

// Returns a maximum of two uppercase initials from a name.
export function contactInitials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map(w => w[0]?.toUpperCase() || '')
    .join('')
}

// Changes the raw birthday of a contact into a civil "YYYY-MM-DD" seed for
// the yearly recurrence. The raw value is a vCard BDAY: "1990-01-15",
// "19900115", or "--01-15" or "--0115" with no year. An unknown year maps to
// 1900, because the seed anchors only the month and the day. Returns null
// when it cannot parse the value.
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

// Returns true when the year of the seed is real, and not the 1900
// placeholder for an unknown year.
export function birthdayYearKnown(seed: string): boolean {
  return !seed.startsWith('1900-')
}
