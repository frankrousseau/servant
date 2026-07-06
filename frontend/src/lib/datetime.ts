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

function toDate(iso: string | null | undefined): Date | null {
  if (!iso) return null
  const d = new Date(iso)
  return isNaN(d.getTime()) ? null : d
}

export function formatDateTime(
  iso: string | null | undefined,
  opts: Intl.DateTimeFormatOptions = { dateStyle: 'medium', timeStyle: 'short' }
): string {
  const d = toDate(iso)
  return d
    ? d.toLocaleString(undefined, { timeZone: userTimeZone(), ...opts })
    : ''
}

export function formatDate(
  iso: string | null | undefined,
  opts: Intl.DateTimeFormatOptions = { dateStyle: 'medium' }
): string {
  const d = toDate(iso)
  return d
    ? d.toLocaleDateString(undefined, { timeZone: userTimeZone(), ...opts })
    : ''
}

export function formatTime(
  iso: string | null | undefined,
  opts: Intl.DateTimeFormatOptions = { hour: '2-digit', minute: '2-digit' }
): string {
  const d = toDate(iso)
  return d
    ? d.toLocaleTimeString(undefined, { timeZone: userTimeZone(), ...opts })
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
  const guess = new Date(`${dateStr}T${timeStr}:00Z`).getTime()
  return new Date(guess - tzOffsetMs(zone, guess)).toISOString()
}

// A UTC ISO string -> its wall-clock parts in `tz`, for pre-filling date/time
// inputs when editing.
export function utcToZonedParts(
  iso: string,
  tz = userTimeZone()
): { date: string; time: string } {
  const zone = tz || Intl.DateTimeFormat().resolvedOptions().timeZone
  const dtf = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  })
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
