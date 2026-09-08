import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import AgentMemoryApp from './AgentMemoryApp.vue'

import type { MemoryFile } from './tree'

function memoryFile(overrides: Partial<MemoryFile> = {}): MemoryFile {
  return {
    id: '1',
    path: 'memory/proj/MEMORY.md',
    project: 'proj',
    tool: 'claude',
    sha256: 'sha-old',
    size: 5,
    updated_at: '2026-01-01T00:00:00Z',
    body: '# Hello',
    ...overrides
  }
}

function jsonRes(data: unknown, ok = true, status = 200) {
  return { ok, status, json: async () => ({ data }) } as Response
}

function makeCtx(fetchMock: ReturnType<typeof vi.fn>) {
  return {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: { list: vi.fn().mockResolvedValue([]) },
      upload: vi.fn(),
      fetch: fetchMock
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
}

describe('AgentMemoryApp', () => {
  it('renders file buttons from the stubbed manifest', async () => {
    const fetchMock = vi.fn(async () => jsonRes([memoryFile()]))
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledWith('/api/agent_memory?include=body')
    const fileButton = wrapper.find('button.file')
    expect(fileButton.exists()).toBe(true)
    expect(fileButton.text()).toBe('MEMORY.md')
  })

  it('shows the rendered markdown when a file is selected', async () => {
    const fetchMock = vi.fn(async () =>
      jsonRes([memoryFile({ body: '# Hello' })])
    )
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('button.file').trigger('click')
    await flushPromises()

    expect(wrapper.find('.markdown').html()).toContain('<h1>Hello</h1>')
  })

  it('edits then saves, posting the edited body and updating the row from the response', async () => {
    const original = memoryFile()
    const fetchMock = vi.fn(async (_path: string, opts?: RequestInit) => {
      if (!opts) return jsonRes([original])
      if (opts.method === 'POST') {
        return jsonRes([
          {
            id: original.id,
            path: original.path,
            project: original.project,
            tool: original.tool,
            sha256: 'sha-new',
            size: 999,
            updated_at: '2026-02-02T00:00:00Z'
          }
        ])
      }
      return jsonRes([])
    })
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('button.file').trigger('click')
    await flushPromises()
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Edit')!
      .trigger('click')
    await wrapper.find('textarea.editor').setValue('edited body')
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Save')!
      .trigger('click')
    await flushPromises()

    expect(fetchMock).toHaveBeenCalledWith('/api/agent_memory', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        files: [{ path: original.path, body: 'edited body' }]
      })
    })

    // The row's size (a proxy for sha256/updated_at, neither rendered
    // directly) reflects the server's manifest, not the stale local one.
    expect(wrapper.find('.viewer-head').text()).toContain('999 bytes')
    expect(wrapper.find('.markdown').text()).toContain('edited body')
  })

  it('deletes after confirmation and removes the file from the tree', async () => {
    const original = memoryFile()
    const fetchMock = vi.fn(async (_path: string, opts?: RequestInit) => {
      if (!opts) return jsonRes([original])
      if (opts.method === 'DELETE') return { ok: true, status: 204 } as Response
      return jsonRes([])
    })
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('button.file').trigger('click')
    await flushPromises()
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Delete')!
      .trigger('click')
    await flushPromises()

    expect(ctx.confirm.ask).toHaveBeenCalled()
    expect(fetchMock).toHaveBeenCalledWith(
      `/api/agent_memory?path=${encodeURIComponent(original.path)}`,
      { method: 'DELETE' }
    )
    expect(wrapper.find('button.file').exists()).toBe(false)
  })

  it('shows the load error in the tree pane', async () => {
    const fetchMock = vi.fn(
      async () => ({ ok: false, status: 500 }) as Response
    )
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.find('.tree .error').text()).toContain('HTTP 500')
  })

  it('shows actionError in the viewer when save fails, tree stays visible', async () => {
    const original = memoryFile()
    const fetchMock = vi.fn(async (_path: string, opts?: RequestInit) => {
      if (!opts) return jsonRes([original])
      if (opts.method === 'POST') return { ok: false, status: 422 } as Response
      return jsonRes([])
    })
    const ctx = makeCtx(fetchMock)
    const wrapper = mount(AgentMemoryApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('button.file').trigger('click')
    await flushPromises()
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Edit')!
      .trigger('click')
    await wrapper
      .findAll('button')
      .find(button => button.text() === 'Save')!
      .trigger('click')
    await flushPromises()

    expect(wrapper.find('.viewer .error').text()).toContain('HTTP 422')
    expect(wrapper.find('.tree').exists()).toBe(true)
    expect(wrapper.find('button.file').exists()).toBe(true)
  })
})
