import MarkdownIt from 'markdown-it'

// Renderer for agent reports: the text comes from a model, so it is treated as
// untrusted input. html: false (the default) escapes any markup it emits, which
// is what makes the result safe to inject with v-html; markdown-it's own
// validateLink already rejects javascript: and data: URLs.
const md = new MarkdownIt({ breaks: true, linkify: true })

// A report may well link outside the instance: open those in a new tab, and
// never hand the opener over.
const defaultLink =
  md.renderer.rules.link_open ||
  ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options))

md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  const href = String(tokens[idx].attrGet('href') ?? '')
  // Anchors inside the report stay in place.
  if (!href.startsWith('#')) {
    tokens[idx].attrSet('target', '_blank')
    tokens[idx].attrSet('rel', 'noopener noreferrer')
  }
  return defaultLink(tokens, idx, options, env, self)
}

// A model asked for a comparison answers with a table, and a wide one would
// otherwise stretch the whole panel: give it its own scroll area.
md.renderer.rules.table_open = () => '<div class="md-table-wrap"><table>'
md.renderer.rules.table_close = () => '</table></div>'

// Checklists read as checklists rather than as "[ ] item". Inputs are disabled:
// a report is a record, not something to tick off.
function renderTaskLists(html: string): string {
  return html.replace(
    /<li>(\s*)\[([ xX])\]\s/g,
    (_m, space: string, mark: string) =>
      `<li class="md-task">${space}<input type="checkbox" disabled${
        mark === ' ' ? '' : ' checked'
      } /> `
  )
}

export function renderMarkdown(source: string): string {
  return renderTaskLists(md.render(source || ''))
}
