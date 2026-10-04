// Tags and relations are in contact.data (entries without a schema). These
// keys are safe across syncs. The CardDAV PUT merges data, and the vCard
// connector never updates entries that exist. As a result, these keys stay
// after phone edits and re-imports.
import type { Entry } from '../types'

export const RELATION_TYPES = [
  'partner',
  'parent',
  'child',
  'sibling',
  'friend',
  'colleague'
] as const

// The six types above are only suggestions. It is possible to store any
// normalized label ("mentor", "landlord", ...). As a result, the type is a
// plain string.
export type RelationType = string

export interface Relation {
  contact_id: string
  type: RelationType
}

const MAX_TYPE_LENGTH = 30

export function normalizeRelationType(raw: string): RelationType {
  return raw.trim().toLowerCase().replace(/\s+/g, ' ').slice(0, MAX_TYPE_LENGTH)
}

export function relationLabel(type: string): string {
  return type.charAt(0).toUpperCase() + type.slice(1)
}

// The stored type describes the linked contact in relation to the entry that
// holds it. For example, "parent" on Alice with a link to Bob means that Bob
// is the parent of Alice. As a result, the reciprocal entry holds the inverse
// type. Only parent and child are directional. All the other types are
// symmetric, custom types included.
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
      typeof (r as Relation).type === 'string' &&
      (r as Relation).type.trim() !== ''
  )
  // Other API clients can write a contact_id that is well-formed but
  // duplicated. Without this map, it renders with a duplicate :key. The last
  // relation wins.
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
