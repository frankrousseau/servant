// Tags and relations live in contact.data (schemaless entries). Safe across
// syncs: the CardDAV PUT merges data and the vCard connector never updates
// existing entries, so these keys survive phone edits and re-imports.
import type { Entry } from '../types'

export const RELATION_TYPES = [
  'partner',
  'parent',
  'child',
  'sibling',
  'friend',
  'colleague'
] as const

export type RelationType = (typeof RELATION_TYPES)[number]

export interface Relation {
  contact_id: string
  type: RelationType
}

export function relationLabel(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1)
}

// The stored type describes the linked contact relative to the entry that
// holds it ("parent" on Alice pointing at Bob = Bob is Alice's parent), so
// the reciprocal entry carries the inverse.
export function inverseType(type: RelationType): RelationType {
  if (type === 'parent') return 'child'
  if (type === 'child') return 'parent'
  return type
}

export function normalizeTags(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  const out: string[] = []
  for (const t of raw) {
    if (typeof t !== 'string') continue
    const tag = t.trim().toLowerCase()
    if (tag && !out.includes(tag)) out.push(tag)
  }
  return out
}

export function tagsOf(entry: Entry): string[] {
  return normalizeTags(entry.data.tags)
}

export function relationsOf(entry: Entry): Relation[] {
  const raw = entry.data.relations
  if (!Array.isArray(raw)) return []
  const filtered = raw.filter(
    (r): r is Relation =>
      !!r &&
      typeof r === 'object' &&
      typeof (r as Relation).contact_id === 'string' &&
      (RELATION_TYPES as readonly string[]).includes((r as Relation).type)
  )
  // A well-formed but duplicated contact_id (writable by other API clients)
  // would otherwise render with a duplicate :key; last one wins.
  const byContact = new Map<string, Relation>()
  for (const r of filtered) byContact.set(r.contact_id, r)
  return [...byContact.values()]
}

export function withRelation(
  relations: Relation[],
  contactId: string,
  type: RelationType
): Relation[] {
  return [
    ...withoutRelation(relations, contactId),
    { contact_id: contactId, type }
  ]
}

export function withoutRelation(
  relations: Relation[],
  contactId: string
): Relation[] {
  return relations.filter(r => r.contact_id !== contactId)
}
