export interface Item {
  text: string
  done: boolean
}

// One item per line of a pasted list: `- x`, `* x`, `+ x`, `• x`, `1. x`,
// `- [ ] x`, `- [x] x` (Notion todos) or bare `[ ] x`. Indentation is
// flattened. Returns null when any non-empty line is not a list line:
// the paste is not a list and should go through untouched.
export function parseListText(text: string): Item[] | null {
  const lines = text.split(/\r?\n/).filter(l => l.trim())
  const items: Item[] = []
  for (const line of lines) {
    const m = /^\s*(?:([-*+•]|\d+[.)])\s+)?(?:\[([ xX])\]\s*)?(.*)$/.exec(line)
    if (!m || (!m[1] && !m[2])) return null
    const content = m[3].trim()
    if (content)
      items.push({ text: content, done: m[2]?.toLowerCase() === 'x' })
  }
  return items.length ? items : null
}

export function itemsToMarkdown(items: Item[]): string {
  return items.map(i => `- [${i.done ? 'x' : ' '}] ${i.text}`).join('\n')
}
