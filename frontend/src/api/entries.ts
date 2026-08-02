// Every call to /api/entries, named. Views and the app plugin context both go
// through here, so paging, envelopes and query names live in one place instead
// of being retyped at each call site.
import type { Entry, PaginationMeta } from '../types'
import { apiJson } from '../composables/apiClient'

export interface AggregateBucket {
  /** Local day "YYYY-MM-DD", week's Monday "YYYY-MM-DD", "YYYY-MM" or "YYYY". */
  bucket: string
  value: number
}

export type EntryFilters = Record<string, string>

/** One page, with the meta a pager needs. */
export async function listEntriesPage(
  filters: EntryFilters = {}
): Promise<{ data: Entry[]; meta: PaginationMeta }> {
  return apiJson<{ data: Entry[]; meta: PaginationMeta }>(
    'GET',
    '/api/entries',
    { params: filters }
  )
}

/**
 * Every match, paged through transparently. Bounded pages rather than one
 * huge per_page: a single capped request silently dropped entries past the cap
 * and sent one oversized payload.
 */
export async function listEntries(
  filters: EntryFilters = {}
): Promise<Entry[]> {
  const perPage = 1000
  const all: Entry[] = []
  let page = 1
  let totalPages = 1
  do {
    const res = await listEntriesPage({
      ...filters,
      per_page: String(perPage),
      page: String(page)
    })
    all.push(...res.data)
    totalPages = res.meta?.total_pages ?? page
    page++
  } while (page <= totalPages)
  return all
}

export async function getEntry(id: string): Promise<Entry> {
  const res = await apiJson<{ data: Entry }>('GET', `/api/entries/${id}`)
  return res.data
}

export async function createEntry(
  attrs: Record<string, unknown>
): Promise<Entry> {
  const res = await apiJson<{ data: Entry }>('POST', '/api/entries', {
    body: attrs
  })
  return res.data
}

export async function updateEntry(
  id: string,
  attrs: Record<string, unknown>
): Promise<Entry> {
  const res = await apiJson<{ data: Entry }>('PUT', `/api/entries/${id}`, {
    body: attrs
  })
  return res.data
}

export async function deleteEntry(id: string): Promise<void> {
  await apiJson<void>('DELETE', `/api/entries/${id}`)
}

/** Bulk delete by kind and/or source: the same filters the list is read with. */
export async function deleteEntriesMatching(
  filters: EntryFilters
): Promise<{ deleted: number }> {
  const query = new URLSearchParams(filters).toString()
  return apiJson<{ deleted: number }>('DELETE', `/api/entries?${query}`)
}

/** Per-kind counts, plus the overall total the dashboard headlines. */
export async function entryStats(): Promise<{
  data: Record<string, number>
  total: number
}> {
  return apiJson<{ data: Record<string, number>; total: number }>(
    'GET',
    '/api/entries/stats'
  )
}

/** Per-kind counts per local day, for the dashboard's activity strip. */
export async function dailyStats(
  days: number
): Promise<Record<string, Record<string, number>>> {
  const res = await apiJson<{
    data: Record<string, Record<string, number>>
  }>('GET', '/api/entries/stats/daily', { params: { days: String(days) } })
  return res.data
}

/** Server-side COUNT/SUM bucketed by local day, week, month or year. */
export async function aggregateEntries(
  params: Record<string, string>
): Promise<AggregateBucket[]> {
  const res = await apiJson<{ data: AggregateBucket[] }>(
    'GET',
    '/api/entries/aggregate',
    { params }
  )
  return res.data
}

export async function listKinds(): Promise<string[]> {
  const res = await apiJson<{ data: string[] }>('GET', '/api/entries/kinds')
  return res.data
}

export async function listSources(): Promise<string[]> {
  const res = await apiJson<{ data: string[] }>('GET', '/api/entries/sources')
  return res.data
}
