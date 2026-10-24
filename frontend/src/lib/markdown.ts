import MarkdownIt from 'markdown-it'

// The renderer for agent reports. The text comes from a model, so it is
// untrusted input. html: false (the default) escapes all markup from the
// model. That makes the result safe to inject with v-html. The validateLink
// of markdown-it already rejects javascript: and data: URLs.
const md = new MarkdownIt({ breaks: true, linkify: true })

// A report can link outside the instance. Open those links in a new tab, and
// never give them the opener.
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

// A model answers a request for a comparison with a table. A wide table
// would stretch the full panel, so give the table its own scroll area.
md.renderer.rules.table_open = () => '<div class="md-table-wrap"><table>'
md.renderer.rules.table_close = () => '</table></div>'

// Checklists show as checklists and not as "[ ] item". The inputs are
// disabled: a report is a record, not a list to tick off.
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
