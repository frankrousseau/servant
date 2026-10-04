// The visual identity of an entry kind: a glyph and a tint. With them, a mixed
// list stays readable without a legend. The kinds that are not in the table
// fall back to neutral.
export const KIND_CONFIG: Record<string, { icon: string; color: string }> = {
  transaction: { icon: '↔', color: '#9d7bff' },
  bank_tx: { icon: '↔', color: '#4a9c6d' },
  blockchain_tx: { icon: '⬡', color: '#9b6cff' },
  article: { icon: '¶', color: '#f0a06c' },
  email: { icon: '@', color: '#5cc98a' },
  photo: { icon: '◻', color: '#c96cd0' },
  contact: { icon: '●', color: '#6ccec9' },
  note: { icon: '✎', color: '#e0d56c' },
  event: { icon: '▣', color: '#e07c5a' },
  invoice: { icon: '¤', color: '#8b6cff' },
  health: { icon: '♥', color: '#e05577' },
  checklist: { icon: '☑', color: '#6c9bd0' }
}

export function kindIcon(kind: string): string {
  return KIND_CONFIG[kind]?.icon ?? '·'
}

export function kindColor(kind: string): string {
  return KIND_CONFIG[kind]?.color ?? '#8b8fa3'
}
