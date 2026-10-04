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

// Names that are not written the same but mean the same person: same words
// in another order ("DUPONT Jeanne"), or one typo apart once long enough for
// a typo to be the likeliest explanation.
const TYPO_MIN_LENGTH = 5
const TYPO_WIDE_LENGTH = 10

export function similarNames(a: string, b: string): boolean {
  if (a === b) return true
  if (a.split(' ').sort().join(' ') === b.split(' ').sort().join(' '))
    return true
  const shortest = Math.min(a.length, b.length)
  if (shortest < TYPO_MIN_LENGTH) return false
  const budget = shortest >= TYPO_WIDE_LENGTH ? 2 : 1
  return Math.abs(a.length - b.length) <= budget && editDistance(a, b) <= budget
}

// ponytail: plain Levenshtein on short strings; names are a few dozen chars.
function editDistance(a: string, b: string): number {
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i)
  for (let i = 1; i <= a.length; i++) {
    const current = [i]
    for (let j = 1; j <= b.length; j++) {
      const substitution = previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, substitution)
    }
    previous = current
  }
  return previous[b.length]
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

  // Looser name matches need a pairwise pass: similar full names, and a bare
  // first name against the one contact whose name carries it (two candidates
  // would mean guessing, so that one stays alone).
  const names = contacts.map(entry => {
    const name = contactName(entry)
    return name === UNNAMED ? '' : normalizeName(name)
  })
  names.forEach((name, index) => {
    if (!name) return
    for (let other = index + 1; other < names.length; other++) {
      if (names[other] && similarNames(name, names[other])) {
        matched.push({ a: index, b: other, reason: 'name' })
        union(index, other)
      }
    }
    if (name.includes(' ')) return
    const carriers = names.flatMap((candidate, other) =>
      other !== index && candidate.split(' ').includes(name) ? [other] : []
    )
    if (carriers.length === 1) {
      matched.push({ a: index, b: carriers[0], reason: 'name' })
      union(index, carriers[0])
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
