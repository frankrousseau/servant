// Memory files, skills and Cursor rules open with a YAML frontmatter block
// that markdown-it would render as a rule and stray paragraphs. Split it off
// as flat key/value pairs (one nesting level, "metadata.type") for display;
// the stored body keeps it verbatim.

export interface FrontmatterField {
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
      if (value !== '') fields.push({ key, value })
    } else if (parent) {
      fields.push({ key: `${parent}.${key}`, value })
    }
  }

  return { fields, content: body.slice(match[0].length) }
}
