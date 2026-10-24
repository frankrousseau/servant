// Memory files, skills and Cursor rules start with a YAML frontmatter block.
// markdown-it renders this block as a rule and stray paragraphs. Split the
// block into flat fields for display. There is one level of nesting: `group`
// is the parent key, shown as a tag, and is "" at the top level. The stored
// body keeps the block verbatim.

export interface FrontmatterField {
  group: string
  key: string
  value: string
}

export interface SplitBody {
  fields: FrontmatterField[]
  content: string
}

const BLOCK = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/
const LINE = /^(\s*)([\w.-]+):[ \t]*(.*)$/

export function splitFrontmatter(body: string): SplitBody {
  const match = BLOCK.exec(body)
  if (!match) return { fields: [], content: body }

  const fields: FrontmatterField[] = []
  let parent = ''
  for (const line of match[1].split('\n')) {
    const parsed = LINE.exec(line)
    if (!parsed) continue
    const [, indent, key, value] = parsed
    if (indent.length === 0) {
      parent = value === '' ? key : ''
      if (value !== '') fields.push({ group: '', key, value })
    } else if (parent) {
      fields.push({
        group: parent === 'metadata' ? 'meta' : parent,
        key,
        value
      })
    }
  }

  return { fields, content: body.slice(match[0].length) }
}
