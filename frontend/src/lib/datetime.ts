// Date and time formatting that knows the timezone. The server stores the
// timestamps in UTC. All that the user sees renders in the preferred IANA
// timezone of the user. When that preference is unknown, it renders in the
// timezone of the browser. The tz database is in the browser through Intl,
// so no dependency is necessary.
import { useAuthStore } from '../stores/auth'

// Returns the preferred timezone of the user. Returns undefined to let Intl
// use the browser default (for example before login). "" counts as unset.
export function userTimeZone(): string | undefined {
  try {
    const tz = useAuthStore().user?.timezone
    return tz && tz !== '' ? tz : undefined
  } catch {
    return undefined
  }
}

// The display preferences (Settings > Appearance). The account stores them
// beside the timezone. An unset value on one of the two means "render like
// the browser does". That is the default, and each call did that before
// these preferences.
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

// Sets the option only when the user picked a side. If not, the browser
// decides. This uses hourCycle and not hour12, because hour12 renders
// midnight as "24:00" in some locales.
function hourCycleOpts(): Intl.DateTimeFormatOptions {
  const format = userTimeFormat()
  if (!format) return {}
  return { hourCycle: format === '12h' ? 'h12' : 'h23' }
}

// Reads the numeric parts in the timezone of the user, then assembles them in
// the chosen order.
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

// The date preference applies to the default render only. A caller that asks
// for a shape of its own ("Mar 3", a weekday) wants that shape. A global
// setting must not change a label that is compact on purpose.
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

// Returns a media duration as "m:ss" (or "h:mm:ss" after one hour), in the
// style of YouTube.
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00'
  const s = Math.floor(seconds % 60)
  const m = Math.floor((seconds / 60) % 60)
  const h = Math.floor(seconds / 3600)
  const mm = h ? String(m).padStart(2, '0') : String(m)
  return `${h ? h + ':' : ''}${mm}:${String(s).padStart(2, '0')}`
}

// --- Wall-clock <-> UTC conversion (for editing events in the user's tz) ---

// Returns the offset (ms) of `tz` ahead of UTC at the given instant.
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

// Reads a wall-clock date ("YYYY-MM-DD") and time ("HH:MM") in `tz`. Returns
// a UTC ISO string for storage. The default for `tz` is the preference of the
// user, then the timezone of the browser.
export function zonedToUtcISO(
  dateStr: string,
  timeStr: string,
  tz = userTimeZone()
): string {
  const zone = tz || Intl.DateTimeFormat().resolvedOptions().timeZone
  // Read the wall time as UTC, then subtract the offset of the zone. Across a
  // DST boundary, the offset can be different between the naive guess and the
  // true instant. For that reason, compute it again one time, at the first
  // estimate. Two passes give the correct offset for every real transition.
  const guess = new Date(`${dateStr}T${timeStr}:00Z`).getTime()
  const firstPass = guess - tzOffsetMs(zone, guess)
  return new Date(guess - tzOffsetMs(zone, firstPass)).toISOString()
}

// The construction of an Intl.DateTimeFormat is the expensive part of Intl
// (tens of µs). Callers like the dashboard parse hundreds of instants for
// each refresh, so cache one formatter for each timezone.
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

// Changes a UTC ISO string into its wall-clock parts in `tz`. They fill the
// date and time inputs in advance for an edit.
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

// Returns the wall-clock date of today ("YYYY-MM-DD") in the timezone of the
// user.
export function todayInUserTz(tz = userTimeZone()): string {
  return utcToZonedParts(new Date().toISOString(), tz).date
}

// --- Civil dates ("YYYY-MM-DD", no time component; deadlines are days) ---

// Returns today as a local civil date. This agrees with the overdue rule of
// the checklists.
export function todayLocalStr(): string {
  const d = new Date()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${String(d.getDate()).padStart(2, '0')}`
}

// Returns the weekday name of a civil date ("2026-08-14" -> "Friday"). It is
// in English on purpose: the UI copy around it is in English.
export function weekdayName(civilDate: string): string {
  return new Date(`${civilDate}T12:00:00Z`).toLocaleDateString('en-US', {
    weekday: 'long',
    timeZone: 'UTC'
  })
}

// Returns a civil date as a short "Aug 12" label for a due chip.
export function formatDue(due: string): string {
  const [y, m, d] = due.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC'
  })
}

// Returns a coarse "how long ago" for lists and log lines, where the exact
// timestamp is noise. It gives minutes, then hours, then days. After a week,
// it gives the plain local date.
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
