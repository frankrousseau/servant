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

// Plural label of a kind, for counts ("281 Bank transactions"): the table
// holds the ids that do not read as an English word with an s; any other
// kind drops its underscores and takes one.
const KIND_LABELS: Record<string, string> = {
  activity: 'Activities',
  ai_report: 'AI reports',
  bank_tx: 'Bank transactions',
  blockchain_tx: 'Blockchain transactions',
  health: 'Health records',
  prefs: 'Preferences'
}

export function kindLabel(kind: string): string {
  const label = KIND_LABELS[kind] ?? `${kind.replaceAll('_', ' ')}s`
  return label.charAt(0).toUpperCase() + label.slice(1)
}
