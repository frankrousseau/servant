// Duplicate detection for the Contacts app: two contacts are candidates when
// they share an email, a phone number or a name. Groups are the connected
// components of those matches (A~B on email and B~C on name puts the three
// together), each with the reasons that hold it, so the user can judge.
import { contactName } from '../../lib/contact'
import type { Entry } from '../types'

export type DuplicateReason = 'email' | 'phone' | 'name'

export interface DuplicateGroup {
  contacts: Entry[]
  reasons: DuplicateReason[]
}

interface Labeled {
  value?: unknown
}

const UNNAMED = '(unnamed)'
// Phones compare on their trailing digits: "+33 6 12 34 56 78" and
// "06 12 34 56 78" are the same line. Shorter numbers must match whole.
const PHONE_SUFFIX = 9
const MIN_PHONE_DIGITS = 6

export function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase()
}

export function normalizePhone(raw: string): string {
  const digits = raw.replace(/\D/g, '')
  if (digits.length < MIN_PHONE_DIGITS) return ''
  return digits.length > PHONE_SUFFIX ? digits.slice(-PHONE_SUFFIX) : digits
}

// Case, accents and punctuation folded, so "Élodie Durand-Roux" meets
// "elodie durand roux".
export function normalizeName(raw: string): string {
  return raw
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim()
}

function labeledValues(entry: Entry, key: string): string[] {
  const list = entry.data[key]
  if (!Array.isArray(list)) return []
  return list
    .map(item => (item as Labeled)?.value)
    .filter((value): value is string => typeof value === 'string')
}

function keysOf(entry: Entry): { reason: DuplicateReason; key: string }[] {
  const keys: { reason: DuplicateReason; key: string }[] = []
  for (const email of labeledValues(entry, 'emails')) {
    const key = normalizeEmail(email)
    if (key) keys.push({ reason: 'email', key })
  }
  for (const phone of labeledValues(entry, 'phones')) {
    const key = normalizePhone(phone)
    if (key) keys.push({ reason: 'phone', key })
  }
  const name = contactName(entry)
  if (name !== UNNAMED) {
    const key = normalizeName(name)
    if (key) keys.push({ reason: 'name', key })
  }
  return keys
}

export function findDuplicateGroups(contacts: Entry[]): DuplicateGroup[] {
  // Union-find over contact indexes, keyed by the values they share.
  const parent = contacts.map((_, index) => index)
  const find = (index: number): number => {
    while (parent[index] !== index) {
      parent[index] = parent[parent[index]]
      index = parent[index]
    }
    return index
  }
  const union = (a: number, b: number) => {
    parent[find(a)] = find(b)
  }

  const seen = new Map<string, number>()
  const reasonsByRoot = new Map<number, Set<DuplicateReason>>()
  const matched: { a: number; b: number; reason: DuplicateReason }[] = []

  contacts.forEach((entry, index) => {
    for (const { reason, key } of keysOf(entry)) {
      const mapKey = `${reason}:${key}`
      const other = seen.get(mapKey)
      if (other === undefined) seen.set(mapKey, index)
      else if (other !== index) {
        matched.push({ a: other, b: index, reason })
        union(other, index)
      }
    }
  })

  for (const { a, reason } of matched) {
    const root = find(a)
    const reasons = reasonsByRoot.get(root) ?? new Set<DuplicateReason>()
    reasons.add(reason)
    reasonsByRoot.set(root, reasons)
  }

  const members = new Map<number, Entry[]>()
  contacts.forEach((entry, index) => {
    const root = find(index)
    if (!reasonsByRoot.has(root)) return
    const list = members.get(root) ?? []
    list.push(entry)
    members.set(root, list)
  })

  const order: DuplicateReason[] = ['email', 'phone', 'name']
  return [...members.entries()]
    .map(([root, list]) => ({
      contacts: list,
      reasons: order.filter(reason => reasonsByRoot.get(root)!.has(reason))
    }))
    .sort((a, b) =>
      contactName(a.contacts[0]).localeCompare(contactName(b.contacts[0]))
    )
}

// How much a card carries, to preselect the survivor: the fuller one, then
// the older one (its id is the one other data most likely references).
export function contactRichness(entry: Entry): number {
  let score = 0
  for (const key of ['org', 'title', 'address', 'birthday', 'url', 'note'])
    if (typeof entry.data[key] === 'string' && entry.data[key]) score++
  if (entry.data.photo) score += 2
  score += labeledValues(entry, 'emails').length
  score += labeledValues(entry, 'phones').length
  const tags = entry.data.tags
  if (Array.isArray(tags)) score += tags.length
  const relations = entry.data.relations
  if (Array.isArray(relations)) score += relations.length
  return score
}

export function suggestedSurvivor(group: DuplicateGroup): Entry {
  return [...group.contacts].sort(
    (a, b) =>
      contactRichness(b) - contactRichness(a) ||
      a.inserted_at.localeCompare(b.inserted_at)
  )[0]
}
