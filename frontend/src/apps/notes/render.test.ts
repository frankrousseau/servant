import { describe, it, expect } from 'vitest'
import { renderMarkdown, canon, continueListEdit } from './render'

const noneResolved = () => false

describe('renderMarkdown', () => {
  it('escapes raw HTML in the note body (no XSS)', () => {
    const html = renderMarkdown('<script>alert(1)</script>', noneResolved)
    expect(html).not.toContain('<script>')
    expect(html).toContain('&lt;script&gt;')
  })

  it('does not turn a javascript: link into an anchor href', () => {
    const html = renderMarkdown('[click](javascript:alert(1))', noneResolved)
    // markdown-it's default validateLink rejects the scheme, so it stays inert
    // text — never an executable href.
    expect(html).not.toMatch(/href=["']?javascript:/i)
    expect(html).not.toContain('<a')
  })

  it('renders a wikilink as an anchor with an escaped data-target', () => {
    const html = renderMarkdown('see [[My Note]]', () => true)
    expect(html).toContain('class="nt-wikilink"')
    expect(html).toContain('data-target="My Note"')
    expect(html).toContain('>My Note</a>')
  })

  it('flags an unresolved wikilink as new', () => {
    const html = renderMarkdown('[[Ghost]]', noneResolved)
    expect(html).toContain('nt-wikilink--new')
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
