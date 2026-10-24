export interface Item {
  text: string
  done: boolean
  // 1 = sub-item (one level deep); absent = top level
  indent?: number
  // Deadline as "YYYY-MM-DD". The row and the calendar show it.
  due?: string
}

// One item per line of a pasted list: `- x`, `* x`, `+ x`, `• x`, `1. x`,
// `- [ ] x`, `- [x] x` (Notion todos) or bare `[ ] x`. A line indented by
// two or more spaces (or a tab) becomes a sub-item. Deeper nesting clamps
// to that single sub-level. Returns null when a non-empty line is not a
// list line: the paste is not a list and must go through unchanged.
export function parseListText(text: string): Item[] | null {
  const lines = text.split(/\r?\n/).filter(l => l.trim())
  const items: Item[] = []
  for (const line of lines) {
    const m = /^([ \t]*)(?:([-*+•]|\d+[.)])\s+)?(?:\[([ xX])\]\s*)?(.*)$/.exec(
      line
    )
    if (!m || (!m[2] && !m[3])) return null
    const content = m[4].trim()
    if (content) {
      const item: Item = { text: content, done: m[3]?.toLowerCase() === 'x' }
      if (m[1].length >= 2 || m[1].includes('\t')) item.indent = 1
      items.push(item)
    }
  }
  return items.length ? items : null
}

export function itemsToMarkdown(items: Item[]): string {
  return items
    .map(i => `${i.indent ? '  ' : ''}- [${i.done ? 'x' : ' '}] ${i.text}`)
    .join('\n')
}
