// Visual identity of an entry kind: a tint, so a mixed list stays readable
// without a legend (the icon per kind lives in components/KindIcon.vue).
// Kinds absent from the table fall back to neutral.
export const KIND_COLORS: Record<string, string> = {
  transaction: '#9d7bff',
  bank_tx: '#4a9c6d',
  blockchain_tx: '#9b6cff',
  article: '#f0a06c',
  email: '#5cc98a',
  photo: '#c96cd0',
  contact: '#6ccec9',
  note: '#e0d56c',
  event: '#e07c5a',
  invoice: '#8b6cff',
  health: '#e05577',
  checklist: '#6c9bd0'
}

export function kindColor(kind: string): string {
  return KIND_COLORS[kind] ?? '#8b8fa3'
}
