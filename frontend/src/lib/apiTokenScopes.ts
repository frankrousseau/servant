// Mirrors Servant.ApiTokens.Scopes on the backend: app domains + data wildcard.
export interface ScopeDomain {
  id: string
  label: string
}

export const SCOPE_DOMAINS: ScopeDomain[] = [
  { id: 'notes', label: 'Notes' },
  { id: 'checklists', label: 'Checklists' },
  { id: 'calendar', label: 'Calendar' },
  { id: 'contacts', label: 'Contacts' },
  { id: 'photos', label: 'Photos' },
  { id: 'files', label: 'Files' },
  { id: 'finance', label: 'Finance' },
  { id: 'trackers', label: 'Trackers' },
  { id: 'data', label: 'All data' }
]

export type AccessLevel = 'none' | 'read' | 'write'

export function scopeFor(domain: string, level: AccessLevel): string | null {
  if (level === 'none') return null
  return domain === 'data' ? `data:${level}` : `app:${domain}:${level}`
}

// levels: domain id -> access level, from the creation form
export function buildScopes(levels: Record<string, AccessLevel>): string[] {
  return SCOPE_DOMAINS.map(d => scopeFor(d.id, levels[d.id] ?? 'none')).filter(
    (s): s is string => s !== null
  )
}
