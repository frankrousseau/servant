import MarkdownIt from 'markdown-it'

import { escapeHtml } from '../escapeHtml'

const md = new MarkdownIt({ breaks: true, linkify: true })

/**
 * Returns the canonical form used for note slugs and to match wikilinks.
 * This function must do the same as the backend `Servant.Notes.canon/1`:
 * trim, change to lower case, collapse whitespace.
 */
export function canon(str: string): string {
  return str.trim().toLowerCase().replace(/\s+/g, ' ')
}

export type MentionKind = 'contact' | 'event' | null

/**
 * Handles Enter pressed at `pos` in `value`. If the caret line is a list item
 * (`- `, `* `, `+ `, `- [ ] `, `1. `, `1) `), returns the edited text and the
 * new caret. The list then continues on the next line: numbers increment and
 * checkboxes reset to unchecked. An empty item exits the list: the function
 * removes the marker and inserts no newline. Returns null when the default
 * newline must occur.
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
    // The item is empty: remove the marker and exit the list.
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

// Apply `fn` only to the text between tags, never in a tag or its attributes.
// markdown-it (html:false) escapes each `<` in text content. As a result, a
// literal `<` always starts a real tag. For this reason, <a>/<span> markup
// injected this way cannot break out of an attribute (for example, `[[x]]`
// in the title="…" of a link). The regex matches runs of text and full tags
// alternately.
function inTextNodes(html: string, fn: (text: string) => string): string {
  return html.replace(/<[^>]*>|[^<]+/g, chunk =>
    chunk[0] === '<' ? chunk : fn(chunk)
  )
}

/**
 * Renders markdown to HTML. Then it changes `@[[mentions]]` into contact or
 * event chips, `[[wikilinks]]` into anchors and `#tags` into pills. An anchor
 * has the `--new` flag when the target note does not exist yet (as in
 * Obsidian). The three passes run only on text nodes, never on tag
 * internals. As a result, they rewrite the wikilink text and tag text that
 * markdown-it left as literal brackets and hashes, and do not corrupt
 * attributes. The mention pass runs first, and then the wikilink pass sees
 * only plain `[[...]]`.
 *
 * `resolve` returns the id of the note that a wikilink points at, or null
 * when there is no such note yet. A resolved link gets a real `href`. As a
 * result, ctrl-click or middle-click opens the note in a new tab. The app
 * still intercepts plain clicks.
 */
export function renderMarkdown(
  body: string,
  resolve: (target: string) => string | null,
  mentionKind: (target: string) => MentionKind = () => null
): string {
  let html = md.render(body || '')

  html = inTextNodes(html, text =>
    text.replace(/@\[\[([^\][]+)\]\]/g, (_m, raw: string) => {
      const target = raw.trim()
      const kind = mentionKind(target)
      const icon = kind === 'event' ? '📅' : '👤'
      const cls = kind ? 'nt-mention' : 'nt-mention nt-mention--unknown'
      return `<a class="${cls}" data-target="${escapeHtml(target)}">${icon} ${escapeHtml(target)}</a>`
    })
  )

  html = inTextNodes(html, text =>
    text.replace(/\[\[([^\][]+)\]\]/g, (_m, raw: string) => {
      const target = raw.trim()
      const id = resolve(target)
      const cls = id ? 'nt-wikilink' : 'nt-wikilink nt-wikilink--new'
      const href = id
        ? ` href="/apps/notes?selected=${encodeURIComponent(id)}"`
        : ''
      return `<a class="${cls}"${href} data-target="${escapeHtml(target)}">${escapeHtml(target)}</a>`
    })
  )

  html = inTextNodes(html, text =>
    text.replace(
      /(^|[\s(>])#([\p{L}0-9_][\p{L}0-9_/-]*)/gu,
      (_m, pre: string, tag: string) =>
        `${pre}<span class="nt-tag">#${escapeHtml(tag)}</span>`
    )
  )

  return html
}
