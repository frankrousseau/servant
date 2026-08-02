// Visual identity of an entry kind: a glyph and a tint, so a mixed list stays
// readable without a legend. Kinds absent from the table fall back to neutral.
export const KIND_CONFIG: Record<string, { icon: string; color: string }> = {
  transaction: { icon: '↔', color: '#9d7bff' },
  article: { icon: '¶', color: '#f0a06c' },
  email: { icon: '@', color: '#5cc98a' },
  photo: { icon: '◻', color: '#c96cd0' },
  contact: { icon: '●', color: '#6ccec9' },
  note: { icon: '✎', color: '#e0d56c' },
  checklist: { icon: '☑', color: '#6c9bd0' }
}

export function kindIcon(kind: string): string {
  return KIND_CONFIG[kind]?.icon ?? '·'
}

export function kindColor(kind: string): string {
  return KIND_CONFIG[kind]?.color ?? '#8b8fa3'
}
