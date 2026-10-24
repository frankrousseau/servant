import type { Entry } from '../types'

// Returns where "open this entry" goes, for each kind. The kinds without a
// dedicated surface fall back to the data browser.
export function entryRoute(e: Entry): string {
  switch (e.kind) {
    case 'note':
      return `/apps/notes?selected=${e.id}`
    case 'checklist':
      return `/apps/checklists?selected=${e.id}`
    case 'event':
      return '/apps/calendar'
    case 'contact':
      return `/contacts/${e.id}`
    case 'photo':
      return `/photos/${e.id}`
    case 'file':
    // The invoices are in the Invoices virtual folder of the Files app.
    case 'invoice':
      return '/apps/files'
    case 'account':
    case 'balance':
    case 'bank_tx':
      return '/apps/finance'
    case 'tracker':
    case 'tracker_log':
      return '/apps/trackers'
    default:
      return `/data?entry=${e.id}`
  }
}
