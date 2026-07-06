import type { Entry } from '../types'

// Where "open this entry" lands, per kind. Kinds without a dedicated
// surface fall back to the data browser.
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
      return '/apps/files'
    default:
      return `/data?entry=${e.id}`
  }
}
