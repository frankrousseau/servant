import MarkdownIt from 'markdown-it'

import { escapeHtml } from '../escapeHtml'

const md = new MarkdownIt({ breaks: true, linkify: true })

/**
 * Canonical form for note slugs and wikilink matching. Must mirror the
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

// Apply `fn` only to the text between tags, never inside a tag or its
// attributes. markdown-it (html:false) escapes any `<` in text content, so a
// literal `<` only ever starts a real tag: injecting <a>/<span> markup this
// way can't break out of an attribute (e.g. `[[x]]` sitting in a link's
// title="…"). Runs of text and whole tags are matched alternately.
function inTextNodes(html: string, fn: (text: string) => string): string {
  return html.replace(/<[^>]*>|[^<]+/g, chunk =>
    chunk[0] === '<' ? chunk : fn(chunk)
  )
}

/**
 * Renders markdown to HTML, then turns `@[[mentions]]` into contact/event
 * chips, `[[wikilinks]]` into anchors (flagged `--new` when the target note
 * doesn't exist yet, à la Obsidian) and `#tags` into pills. The three passes
 * run over text nodes only (never tag internals) so wikilink/tag text that
 * markdown-it left as literal brackets/hashes is rewritten without corrupting
 * attributes. Mentions are replaced first so the wikilink pass only sees
 * plain `[[...]]`.
 *
 * `resolve` returns the id of the note a wikilink points at (null when there
 * is none yet). A resolved link gets a real `href`, so ctrl/middle-click opens
 * the note in a new tab; the app still intercepts plain clicks.
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
