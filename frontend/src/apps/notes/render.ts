import MarkdownIt from 'markdown-it'

import { escapeHtml } from '../escapeHtml'

const md = new MarkdownIt({ breaks: true, linkify: true })

/**
 * Canonical form for note slugs and wikilink matching — must mirror the
 * backend `Servant.Notes.canon/1` (trim, lower-case, collapse whitespace).
 */
export function canon(str: string): string {
  return str.trim().toLowerCase().replace(/\s+/g, ' ')
}

export type MentionKind = 'contact' | 'event' | null

/**
 * Enter pressed at `pos` in `value`: if the caret line is a list item
 * (`- `, `* `, `+ `, `- [ ] `, `1. `, `1) `), returns the edited text and new
 * caret so the list continues on the next line (numbers increment, checkboxes
 * reset to unchecked). An empty item exits the list: the marker is removed and
 * no newline is inserted. Returns null when the default newline should happen.
 */
export function continueListEdit(
  value: string,
  pos: number
): { value: string; pos: number } | null {
  const lineStart = value.lastIndexOf('\n', pos - 1) + 1
  const beforeCaret = value.slice(lineStart, pos)
  const m = beforeCaret.match(/^(\s*)(?:([-*+])( \[[ xX]\] |\s)|(\d+)([.)])\s)/)
  if (!m) return null

  const lineEnd = value.indexOf('\n', pos)
  const fullLine = value.slice(
    lineStart,
    lineEnd === -1 ? value.length : lineEnd
  )
  if (fullLine.trimEnd() === m[0].trimEnd()) {
    // Empty item: drop the marker, exit the list.
    return {
      value: value.slice(0, lineStart) + value.slice(pos),
      pos: lineStart
    }
  }

  const marker =
    m[2] !== undefined
      ? `${m[1]}${m[2]} ${m[3].trim() ? '[ ] ' : ''}`
      : `${m[1]}${Number(m[4]) + 1}${m[5]} `

  return {
    value: value.slice(0, pos) + '\n' + marker + value.slice(pos),
    pos: pos + 1 + marker.length
  }
}

/**
 * Renders markdown to HTML, then turns `@[[mentions]]` into contact/event
 * chips, `[[wikilinks]]` into anchors (flagged `--new` when the target note
 * doesn't exist yet, à la Obsidian) and `#tags` into pills. Post-processing
 * the rendered HTML keeps wikilink/tag text as literal brackets/hashes that
 * markdown-it leaves untouched. Mentions are replaced first so the wikilink
 * pass only sees plain `[[...]]`.
 */
export function renderMarkdown(
  body: string,
  resolved: (target: string) => boolean,
  mentionKind: (target: string) => MentionKind = () => null
): string {
  let html = md.render(body || '')

  html = html.replace(/@\[\[([^\][]+)\]\]/g, (_m, raw: string) => {
    const target = raw.trim()
    const kind = mentionKind(target)
    const icon = kind === 'event' ? '📅' : '👤'
    const cls = kind ? 'nt-mention' : 'nt-mention nt-mention--unknown'
    return `<a class="${cls}" data-target="${escapeHtml(target)}">${icon} ${escapeHtml(target)}</a>`
  })

  html = html.replace(/\[\[([^\][]+)\]\]/g, (_m, raw: string) => {
    const target = raw.trim()
    const cls = resolved(target)
      ? 'nt-wikilink'
      : 'nt-wikilink nt-wikilink--new'
    return `<a class="${cls}" data-target="${escapeHtml(target)}">${escapeHtml(target)}</a>`
  })

  html = html.replace(
    /(^|[\s(>])#([\p{L}0-9_][\p{L}0-9_/-]*)/gu,
    (_m, pre: string, tag: string) =>
      `${pre}<span class="nt-tag">#${escapeHtml(tag)}</span>`
  )

  return html
}
