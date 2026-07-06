export type Recurrence = 'weekly' | 'monthly' | 'yearly'

export function recurrenceOf(data: Record<string, unknown>): Recurrence | null {
  const r = data.recurrence
  return r === 'weekly' || r === 'monthly' || r === 'yearly' ? r : null
}

// All dates below are civil "YYYY-MM-DD" strings in the user's timezone
// (string comparison orders them chronologically).

function dayOfWeek(dateStr: string): number {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Date(y, m - 1, d).getDay()
}

function daysInMonth(y: number, m: number): number {
  return new Date(y, m, 0).getDate()
}

function addDays(dateStr: string, n: number): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const dt = new Date(y, m - 1, d + n)
  const mm = String(dt.getMonth() + 1).padStart(2, '0')
  const dd = String(dt.getDate()).padStart(2, '0')
  return `${dt.getFullYear()}-${mm}-${dd}`
}

// Does an event seeded on `seed` recur on `date`? Occurrences start at the
// seed. Seeds past the end of a shorter month (31st, Feb 29 anniversaries)
// are clamped to that month's last day.
export function occursOn(seed: string, rec: Recurrence, date: string): boolean {
  if (date < seed) return false
  if (date === seed) return true
  const [, sm, sd] = seed.split('-').map(Number)
  const [dy, dm, dd] = date.split('-').map(Number)
  const clamped = Math.min(sd, daysInMonth(dy, dm))
  switch (rec) {
    case 'weekly':
      return dayOfWeek(seed) === dayOfWeek(date)
    case 'monthly':
      return dd === clamped
    case 'yearly':
      return sm === dm && dd === clamped
  }
}

// First occurrence on or after `from`.
// ponytail: linear day scan — bounded by the longest gap (a year + slack)
export function nextOccurrence(
  seed: string,
  rec: Recurrence,
  from: string
): string {
  let cursor = from > seed ? from : seed
  for (let i = 0; i < 400; i++) {
    if (occursOn(seed, rec, cursor)) return cursor
    cursor = addDays(cursor, 1)
  }
  return seed
}
