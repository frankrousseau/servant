import { describe, expect, it } from 'vitest'

import { buildTree } from './tree'
import type { MemoryFile } from './tree'

function file(path: string): MemoryFile {
  return {
    id: path,
    path,
    project: '',
    tool: 'claude',
    sha256: '',
    size: 0,
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('buildTree', () => {
  it('nests paths under labeled roots, folders first, alphabetical', () => {
    const tree = buildTree([
      file('skills/claude/kitsu/SKILL.md'),
      file('memory/servant-elixir/servant-ui.md'),
      file('memory/servant-elixir/MEMORY.md'),
      file('memory/kitsu/MEMORY.md'),
      file('rules/kitsu/style.mdc')
    ])

    expect(tree.map(node => node.name)).toEqual(['Memory', 'Skills', 'Rules'])

    const memory = tree[0]
    expect(memory.children.map(node => node.name)).toEqual([
      'kitsu',
      'servant-elixir'
    ])

    const servant = memory.children[1]
    expect(servant.path).toBe('memory/servant-elixir')
    expect(servant.children.map(node => node.name)).toEqual([
      'MEMORY.md',
      'servant-ui.md'
    ])
    expect(servant.children[0].file?.path).toBe(
      'memory/servant-elixir/MEMORY.md'
    )

    const skill = tree[1].children[0].children[0]
    expect(skill.name).toBe('kitsu')
    expect(skill.children[0].file?.path).toBe('skills/claude/kitsu/SKILL.md')
  })

  it('omits empty roots', () => {
    expect(
      buildTree([file('rules/kitsu/style.mdc')]).map(node => node.name)
    ).toEqual(['Rules'])
  })
})
