import { describe, it, expect } from 'vitest'

import { renderMarkdown } from './markdown'

describe('renderMarkdown', () => {
  it('escapes HTML the model emits', () => {
    const html = renderMarkdown('<script>alert(1)</script>')
    expect(html).not.toContain('<script>')
    expect(html).toContain('&lt;script&gt;')
  })

  it('does not turn a javascript: link into an href', () => {
    const html = renderMarkdown('[click](javascript:alert(1))')
    expect(html).not.toMatch(/href=["']?javascript:/i)
  })

  it('opens external links in a new tab without handing over the opener', () => {
    const html = renderMarkdown('[docs](https://example.com)')
    expect(html).toContain('target="_blank"')
    expect(html).toContain('rel="noopener noreferrer"')
  })

  it('leaves in-report anchors alone', () => {
    const html = renderMarkdown('[top](#summary)')
    expect(html).not.toContain('target="_blank"')
  })

  it('wraps a table so a wide one scrolls instead of stretching the panel', () => {
    const html = renderMarkdown('| a | b |\n| - | - |\n| 1 | 2 |')
    expect(html).toContain('<div class="md-table-wrap"><table>')
    expect(html).toContain('</table></div>')
    expect(html).toContain('<td>1</td>')
  })

  it('renders task lists as disabled checkboxes', () => {
    const html = renderMarkdown('- [ ] todo\n- [x] done')
    expect(html).toContain('<input type="checkbox" disabled />')
    expect(html).toContain('<input type="checkbox" disabled checked />')
    expect(html).not.toContain('[x]')
  })

  it('keeps the usual markdown: headings, emphasis, code, quotes', () => {
    const html = renderMarkdown(
      '# Title\n\n**bold** and `code`\n\n> quoted\n\n```\nblock\n```'
    )
    expect(html).toContain('<h1>Title</h1>')
    expect(html).toContain('<strong>bold</strong>')
    expect(html).toContain('<code>code</code>')
    expect(html).toContain('<blockquote>')
    expect(html).toContain('<pre>')
  })
})
