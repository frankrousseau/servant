// This module gives a name to each call to /api/entries. The views and the
// app plugin context both go through this module. As a result, paging,
// envelopes and query names are in one place, and no call site types them
// again.
import type { Entry, PaginationMeta } from '../types'
import { apiJson } from '../composables/apiClient'

export interface AggregateBucket {
  /** Local day "YYYY-MM-DD", week's Monday "YYYY-MM-DD", "YYYY-MM" or "YYYY". */
  bucket: string
  value: number
}

export type EntryFilters = Record<string, string>

/** Returns one page, with the meta that is necessary for a pager. */
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
 * Returns every match, and goes through the pages for the caller. It uses
 * bounded pages and not one very large per_page. A single capped request
 * dropped the entries after the cap without a warning, and sent one payload
 * that was too large.
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

/**
 * Deletes in bulk by kind, by source or by both. The filters are the same as
 * the filters that read the list.
 */
export async function deleteEntriesMatching(
  filters: EntryFilters
): Promise<{ deleted: number }> {
  const query = new URLSearchParams(filters).toString()
  return apiJson<{ deleted: number }>('DELETE', `/api/entries?${query}`)
}

/**
 * Returns the counts for each kind, and the full total that the dashboard
 * shows as its headline.
 */
export async function entryStats(): Promise<{
  data: Record<string, number>
  total: number
}> {
  return apiJson<{ data: Record<string, number>; total: number }>(
    'GET',
    '/api/entries/stats'
  )
}

/**
 * Returns the counts for each kind and each local day, for the activity strip
 * of the dashboard.
 */
export async function dailyStats(
  days: number
): Promise<Record<string, Record<string, number>>> {
  const res = await apiJson<{
    data: Record<string, Record<string, number>>
  }>('GET', '/api/entries/stats/daily', { params: { days: String(days) } })
  return res.data
}

/**
 * Returns a COUNT or a SUM that the server calculates. The bucket is one of:
 * - a local day
 * - a week
 * - a month
 * - a year
 */
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
