// Timezone-aware date/time formatting. Timestamps are stored in UTC on the
// server; everything user-facing is rendered in the user's preferred IANA
// timezone (falling back to the browser's when unknown). The tz database lives
// in the browser via Intl; no dependency needed.
import { useAuthStore } from '../stores/auth'

// The user's preferred timezone, or undefined to let Intl use the browser
// default (e.g. before login). "" is treated as unset.
export function userTimeZone(): string | undefined {
  try {
    const tz = useAuthStore().user?.timezone
    return tz && tz !== '' ? tz : undefined
  } catch {
    return undefined
  }
}

// Display preferences (Settings > Appearance), stored on the account beside
// the timezone. Unset on either side means "render like the browser does",
// which is the default and what every call did before this existed.
export type TimeFormat = '24h' | '12h'
export type DateFormat = 'dmy' | 'mdy' | 'iso'

export const TIME_FORMATS: { id: TimeFormat; label: string }[] = [
  { id: '24h', label: '24-hour' },
  { id: '12h', label: '12-hour' }
]
export const DATE_FORMATS: { id: DateFormat; label: string }[] = [
  { id: 'dmy', label: '31/12/2026' },
  { id: 'mdy', label: '12/31/2026' },
  { id: 'iso', label: '2026-12-31' }
]

export function userTimeFormat(): TimeFormat | undefined {
  try {
    return (useAuthStore().user?.time_format as TimeFormat) || undefined
  } catch {
    return undefined
  }
}

export function userDateFormat(): DateFormat | undefined {
  try {
    return (useAuthStore().user?.date_format as DateFormat) || undefined
  } catch {
    return undefined
  }
}

// Set only when the user picked a side: left alone, the browser decides.
// hourCycle rather than hour12, which renders midnight as "24:00" in some
// locales.
function hourCycleOpts(): Intl.DateTimeFormatOptions {
  const format = userTimeFormat()
  if (!format) return {}
  return { hourCycle: format === '12h' ? 'h12' : 'h23' }
}

// Numeric parts read in the user's timezone, assembled in the chosen order.
function renderDate(date: Date, format: DateFormat): string {
  const parts: Record<string, string> = {}
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: userTimeZone(),
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  })
  for (const part of fmt.formatToParts(date)) {
    if (part.type !== 'literal') parts[part.type] = part.value
  }
  if (format === 'iso') return `${parts.year}-${parts.month}-${parts.day}`
  if (format === 'mdy') return `${parts.month}/${parts.day}/${parts.year}`
  return `${parts.day}/${parts.month}/${parts.year}`
}

function toDate(iso: string | null | undefined): Date | null {
  if (!iso) return null
  const d = new Date(iso)
  return isNaN(d.getTime()) ? null : d
}

// The date preference applies to the default rendering only. A caller asking
// for a shape of its own ("Mar 3", a weekday) means it, and a global setting
// has no business rewriting a deliberately compact label.
export function formatDateTime(
  iso: string | null | undefined,
  opts?: Intl.DateTimeFormatOptions
): string {
  const d = toDate(iso)
  if (!d) return ''
  const format = userDateFormat()
  if (!opts && format) return `${renderDate(d, format)} ${formatTime(iso)}`
  return d.toLocaleString(undefined, {
    timeZone: userTimeZone(),
    ...hourCycleOpts(),
    ...(opts || { dateStyle: 'medium', timeStyle: 'short' })
  })
}

export function formatDate(
  iso: string | null | undefined,
  opts?: Intl.DateTimeFormatOptions
): string {
  const d = toDate(iso)
  if (!d) return ''
  const format = userDateFormat()
  if (!opts && format) return renderDate(d, format)
  return d.toLocaleDateString(undefined, {
    timeZone: userTimeZone(),
    ...(opts || { dateStyle: 'medium' })
  })
}

export function formatTime(
  iso: string | null | undefined,
  opts: Intl.DateTimeFormatOptions = { hour: '2-digit', minute: '2-digit' }
): string {
  const d = toDate(iso)
  return d
    ? d.toLocaleTimeString(undefined, {
        timeZone: userTimeZone(),
        ...hourCycleOpts(),
        ...opts
      })
    : ''
}

// Media duration as "m:ss" (or "h:mm:ss" past the hour), YouTube-style.
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00'
  const s = Math.floor(seconds % 60)
  const m = Math.floor((seconds / 60) % 60)
  const h = Math.floor(seconds / 3600)
  const mm = h ? String(m).padStart(2, '0') : String(m)
  return `${h ? h + ':' : ''}${mm}:${String(s).padStart(2, '0')}`
}

// --- Wall-clock <-> UTC conversion (for editing events in the user's tz) ---

// Offset (ms) that `tz` is ahead of UTC at the given instant.
function tzOffsetMs(tz: string, utcMs: number): number {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit'
  })
  const m: Record<string, string> = {}
  for (const p of dtf.formatToParts(new Date(utcMs))) {
    if (p.type !== 'literal') m[p.type] = p.value
  }
  const asUTC = Date.UTC(
    +m.year,
    +m.month - 1,
    +m.day,
    +m.hour,
    +m.minute,
    +m.second
  )
  return asUTC - utcMs
}

// A wall-clock date ("YYYY-MM-DD") + time ("HH:MM") interpreted in `tz` -> UTC
// ISO string for storage. `tz` defaults to the user's preference / browser.
export function zonedToUtcISO(
  dateStr: string,
  timeStr: string,
  tz = userTimeZone()
): string {
  const zone = tz || Intl.DateTimeFormat().resolvedOptions().timeZone
  // Treat the wall time as if it were UTC, then subtract the zone's offset.
  // The offset can differ between the naive guess and the true instant across a
  // DST boundary, so recompute it once at the first estimate: two passes pin the
  // correct offset for every real transition.
  const guess = new Date(`${dateStr}T${timeStr}:00Z`).getTime()
  const firstPass = guess - tzOffsetMs(zone, guess)
  return new Date(guess - tzOffsetMs(zone, firstPass)).toISOString()
}

// Intl.DateTimeFormat construction is the expensive part of Intl (tens of µs);
// callers like the dashboard parse hundreds of instants per refresh, so cache
// one formatter per timezone.
const zonedPartsFmts = new Map<string, Intl.DateTimeFormat>()

function zonedPartsFmt(zone: string): Intl.DateTimeFormat {
  let fmt = zonedPartsFmts.get(zone)
  if (!fmt) {
    fmt = new Intl.DateTimeFormat('en-CA', {
      timeZone: zone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit'
    })
    zonedPartsFmts.set(zone, fmt)
  }
  return fmt
}

// A UTC ISO string -> its wall-clock parts in `tz`, for pre-filling date/time
// inputs when editing.
export function utcToZonedParts(
  iso: string,
  tz = userTimeZone()
): { date: string; time: string } {
  const zone = tz || Intl.DateTimeFormat().resolvedOptions().timeZone
  const dtf = zonedPartsFmt(zone)
  const m: Record<string, string> = {}
  for (const p of dtf.formatToParts(new Date(iso))) {
    if (p.type !== 'literal') m[p.type] = p.value
  }
  return {
    date: `${m.year}-${m.month}-${m.day}`,
    time: `${m.hour}:${m.minute}`
  }
}

// Today's wall-clock date ("YYYY-MM-DD") in the user's timezone.
export function todayInUserTz(tz = userTimeZone()): string {
  return utcToZonedParts(new Date().toISOString(), tz).date
}

// --- Civil dates ("YYYY-MM-DD", no time component; deadlines are days) ---

// Today as a local civil date, matching the checklists overdue rule.
export function todayLocalStr(): string {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, '0')}`
}

// A civil date as a short "Aug 12" due-chip label.
export function formatDue(due: string): string {
  const [y, m, d] = due.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC'
  })
}

// Coarse "how long ago" for lists and log lines, where the exact timestamp is
// noise: minutes, then hours, then days, then the plain local date past a week.
export function relativeTime(dateStr: string): string {
  const date = new Date(dateStr)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffSec = Math.floor(diffMs / 1000)
  const diffMin = Math.floor(diffSec / 60)
  const diffHour = Math.floor(diffMin / 60)
  const diffDay = Math.floor(diffHour / 24)

  if (diffSec < 60) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  if (diffHour < 24) return `${diffHour}h ago`
  if (diffDay < 7) return `${diffDay}d ago`
  return date.toLocaleDateString()
}
