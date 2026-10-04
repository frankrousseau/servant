import { describe, it, expect } from 'vitest'

import { renderMarkdown, canon, continueListEdit } from './render'

const noneResolved = () => null
const resolvesTo = (id: string) => () => id

describe('renderMarkdown', () => {
  it('escapes raw HTML in the note body (no XSS)', () => {
    const html = renderMarkdown('<script>alert(1)</script>', noneResolved)
    expect(html).not.toContain('<script>')
    expect(html).toContain('&lt;script&gt;')
  })

  it('does not turn a javascript: link into an anchor href', () => {
    const html = renderMarkdown('[click](javascript:alert(1))', noneResolved)
    // The default validateLink of markdown-it rejects the scheme. As a result,
    // the link stays inert text and never becomes an executable href.
    expect(html).not.toMatch(/href=["']?javascript:/i)
    expect(html).not.toContain('<a')
  })

  it('renders a wikilink as an anchor with an escaped data-target', () => {
    const html = renderMarkdown('see [[My Note]]', resolvesTo('n1'))
    expect(html).toContain('class="nt-wikilink"')
    expect(html).toContain('data-target="My Note"')
    expect(html).toContain('>My Note</a>')
  })

  it('gives a resolved wikilink an href so it opens in a new tab', () => {
    const html = renderMarkdown('see [[My Note]]', resolvesTo('a b/c'))
    expect(html).toContain('href="/apps/notes?selected=a%20b%2Fc"')
  })

  it('flags an unresolved wikilink as new and leaves it without an href', () => {
    const html = renderMarkdown('[[Ghost]]', noneResolved)
    expect(html).toContain('nt-wikilink--new')
    expect(html).not.toContain('href="/apps/notes')
  })

  it('does not emit raw HTML from a wikilink target', () => {
    const html = renderMarkdown('[[<img onerror=x>]]', noneResolved)
    expect(html).not.toContain('<img')
    expect(html).not.toContain('onerror=x>')
  })

  it('renders #tags as pills', () => {
    const html = renderMarkdown('a #project tag', noneResolved)
    expect(html).toContain('class="nt-tag"')
    expect(html).toContain('#project')
  })

  it('does not rewrite wikilink syntax sitting inside an attribute', () => {
    // The [[y]] is in the title="…" of the link. A rewrite there breaks out of
    // the attribute. The [[y]] in the tag must stay as it is.
    const html = renderMarkdown(
      '[a](http://e.com "x [[y]] q")',
      resolvesTo('n1')
    )
    expect(html).toContain('title="x [[y]] q"')
    expect(html).not.toContain('class="nt-wikilink"')
  })

  it('rewrites a wikilink in text even next to an inline tag', () => {
    const html = renderMarkdown('**bold** then [[My Note]]', resolvesTo('n1'))
    expect(html).toContain('<strong>bold</strong>')
    expect(html).toContain('class="nt-wikilink"')
    expect(html).toContain('>My Note</a>')
  })
})

describe('canon', () => {
  it('trims, lowercases and collapses whitespace', () => {
    expect(canon('  Foo   Bar ')).toBe('foo bar')
  })
})

describe('continueListEdit', () => {
  const atEnd = (text: string) => continueListEdit(text, text.length)

  it('continues a dash item', () => {
    expect(atEnd('- one')).toEqual({ value: '- one\n- ', pos: 8 })
  })

  it('continues a star item and keeps indentation', () => {
    expect(atEnd('  * one')).toEqual({ value: '  * one\n  * ', pos: 12 })
  })

  it('increments numbered items', () => {
    expect(atEnd('1. one')).toEqual({ value: '1. one\n2. ', pos: 10 })
    expect(atEnd('9) one')).toEqual({ value: '9) one\n10) ', pos: 11 })
  })

  it('continues a checkbox item unchecked', () => {
    expect(atEnd('- [x] done')).toEqual({
      value: '- [x] done\n- [ ] ',
      pos: 17
    })
  })

  it('removes the marker on an empty item (exit the list)', () => {
    expect(atEnd('- one\n- ')).toEqual({ value: '- one\n', pos: 6 })
    expect(atEnd('- [ ] ')).toEqual({ value: '', pos: 0 })
  })

  it('splits mid-line, carrying the marker to the new line', () => {
    // caret between "one" and " two" in "- one two"
    expect(continueListEdit('- one two', 5)).toEqual({
      value: '- one\n-  two',
      pos: 8
    })
  })

  it('returns null on non-list lines', () => {
    expect(atEnd('plain text')).toBeNull()
    expect(atEnd('-nospace')).toBeNull()
    expect(atEnd('')).toBeNull()
  })
})
