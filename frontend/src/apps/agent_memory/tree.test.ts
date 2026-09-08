import { describe, expect, it } from 'vitest'

import { buildTree } from './tree'
import type { MemoryFile } from './tree'

function file(path: string, tool = 'claude'): MemoryFile {
  return {
    id: path,
    path,
    project: '',
    tool,
    sha256: '',
    size: 0,
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('buildTree', () => {
  it('groups by harness, then section, folders first, alphabetical', () => {
    const tree = buildTree([
      file('skills/claude/kitsu/SKILL.md'),
      file('memory/servant-elixir/servant-ui.md'),
      file('memory/servant-elixir/MEMORY.md'),
      file('memory/kitsu/MEMORY.md'),
      file('rules/kitsu/style.mdc', 'cursor'),
      file('skills/shared/brainstorming/SKILL.md', 'shared')
    ])

    expect(tree.map(node => node.name)).toEqual([
      'Claude Code',
      'Cursor',
      'Shared'
    ])

    const claude = tree[0]
    expect(claude.children.map(node => node.name)).toEqual(['Memory', 'Skills'])

    const memory = claude.children[0]
    expect(memory.children.map(node => node.name)).toEqual([
      'kitsu',
      'servant-elixir'
    ])

    const servant = memory.children[1]
    expect(servant.path).toBe('claude/memory/servant-elixir')
    expect(servant.children.map(node => node.name)).toEqual([
      'MEMORY.md',
      'servant-ui.md'
    ])
    expect(servant.children[0].file?.path).toBe(
      'memory/servant-elixir/MEMORY.md'
    )

    // The harness segment of skills/<tool>/<name> is what the root already says.
    const skill = claude.children[1].children[0]
    expect(skill.name).toBe('kitsu')
    expect(skill.children[0].file?.path).toBe('skills/claude/kitsu/SKILL.md')

    const cursor = tree[1]
    expect(cursor.children.map(node => node.name)).toEqual(['Rules'])
    expect(cursor.children[0].children[0].name).toBe('kitsu')

    const shared = tree[2]
    expect(shared.children[0].name).toBe('Skills')
    expect(shared.children[0].children[0].name).toBe('brainstorming')
  })

  it('omits empty harnesses', () => {
    expect(
      buildTree([file('rules/kitsu/style.mdc', 'cursor')]).map(
        node => node.name
      )
    ).toEqual(['Cursor'])
  })
})
