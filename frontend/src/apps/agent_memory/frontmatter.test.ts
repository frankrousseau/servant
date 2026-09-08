import { describe, expect, it } from 'vitest'

import { splitFrontmatter } from './frontmatter'

describe('splitFrontmatter', () => {
  it('extracts flat and one-level nested fields and returns the rest', () => {
    const body = [
      '---',
      'name: servant-ui-doctrine',
      'description: single-workplace pages',
      'metadata:',
      '  type: feedback',
      '  originSessionId: abc',
      '---',
      '',
      '# Body',
      'text'
    ].join('\n')

    expect(splitFrontmatter(body)).toEqual({
      fields: [
        { key: 'name', value: 'servant-ui-doctrine' },
        { key: 'description', value: 'single-workplace pages' },
        { key: 'metadata.type', value: 'feedback' },
        { key: 'metadata.originSessionId', value: 'abc' }
      ],
      content: '\n# Body\ntext'
    })
  })

  it('leaves a body without frontmatter untouched', () => {
    expect(splitFrontmatter('# Plain\n\n---\n\nrule')).toEqual({
      fields: [],
      content: '# Plain\n\n---\n\nrule'
    })
  })
})
