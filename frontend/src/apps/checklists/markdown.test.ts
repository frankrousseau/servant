import { describe, it, expect } from 'vitest'

import { itemsToMarkdown, parseListText } from './markdown'

describe('parseListText', () => {
  it('parses dash, star, plus and bullet-point lists', () => {
    expect(parseListText('- Lait\n* Pain\n+ Beurre\n• Sel')).toEqual([
      { text: 'Lait', done: false },
      { text: 'Pain', done: false },
      { text: 'Beurre', done: false },
      { text: 'Sel', done: false }
    ])
  })

  it('parses checkbox lists (Notion todos) with their done state', () => {
    expect(parseListText('- [ ] Lait\n- [x] Pain\n- [X] Œufs')).toEqual([
      { text: 'Lait', done: false },
      { text: 'Pain', done: true },
      { text: 'Œufs', done: true }
    ])
  })

  it('parses numbered lists and bare checkboxes', () => {
    expect(parseListText('1. Un\n2) Deux\n[ ] Trois')).toEqual([
      { text: 'Un', done: false },
      { text: 'Deux', done: false },
      { text: 'Trois', done: false }
    ])
  })

  it('keeps one level of indentation and skips blank or empty-marker lines', () => {
    expect(parseListText('- A\n\n  - [ ] B\n- ')).toEqual([
      { text: 'A', done: false },
      { text: 'B', done: false, indent: 1 }
    ])
  })

  it('clamps deeper nesting to a single sub-level', () => {
    expect(parseListText('- A\n\t- B\n      - C')).toEqual([
      { text: 'A', done: false },
      { text: 'B', done: false, indent: 1 },
      { text: 'C', done: false, indent: 1 }
    ])
  })

  it('returns null for plain text or mixed content', () => {
    expect(parseListText('just a sentence')).toBeNull()
    expect(parseListText('- A\nnot a list line')).toBeNull()
    expect(parseListText('')).toBeNull()
    expect(parseListText('-no space after dash')).toBeNull()
  })
})

describe('itemsToMarkdown', () => {
  it('renders checkbox lines that round-trip through parseListText', () => {
    const items = [
      { text: 'Lait', done: true },
      { text: 'Pain', done: false }
    ]
    const md = itemsToMarkdown(items)
    expect(md).toBe('- [x] Lait\n- [ ] Pain')
    expect(parseListText(md)).toEqual(items)
  })

  it('indents sub-items with two spaces and round-trips them', () => {
    const items = [
      { text: 'Gâteau', done: false },
      { text: 'Farine', done: true, indent: 1 }
    ]
    const md = itemsToMarkdown(items)
    expect(md).toBe('- [ ] Gâteau\n  - [x] Farine')
    expect(parseListText(md)).toEqual(items)
  })
})
