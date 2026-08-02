import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import FilesApp from './FilesApp.vue'

import type { Entry } from '../types'

function fileEntry(
  id: string,
  filename: string,
  data: Record<string, unknown> = {}
): Entry {
  return {
    id,
    kind: 'file',
    source: 'files_app',
    external_id: null,
    title: filename,
    occurred_at: null,
    data: { filename, parent_id: null, ...data },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function makeCtx(files: Entry[]) {
  const store = [...files]
  const create = vi.fn(async (attrs: Record<string, unknown>) => {
    const created = {
      ...fileEntry('new', 'New folder'),
      ...attrs
    } as unknown as Entry
    store.push(created)
    return created
  })
  const update = vi.fn(async (id: string, attrs: Record<string, unknown>) => ({
    ...store.find(f => f.id === id)!,
    ...attrs
  }))
  const del = vi.fn(async (id: string) => {
    const i = store.findIndex(f => f.id === id)
    if (i >= 0) store.splice(i, 1)
  })
  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async (filters?: Record<string, string>) =>
          filters?.kind === 'file' ? [...store] : []
        ),
        update,
        create,
        delete: del
      },
      upload: vi.fn(),
      fetch: vi.fn(async () => ({ ok: true, json: async () => ({ data: [] }) }))
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
  return { ctx, create, update, del }
}

async function createFolder(wrapper: ReturnType<typeof mount>) {
  const btn = wrapper
    .findAll('.fs-btn')
    .find(b => b.text().includes('+ Folder'))!
  await btn.trigger('click')
  await flushPromises()
  await flushPromises()
}

describe('FilesApp folder creation', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/')
    // Keep the virtual mounts (Notes, Photos, ...) out of the row list so
    // .fs-name selectors hit real files only.
    localStorage.setItem('servant_files_show_virtual', '0')
  })

  it('creates the folder immediately and opens inline naming', async () => {
    const { ctx, create } = makeCtx([])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await createFolder(wrapper)

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'file',
        data: expect.objectContaining({ is_folder: true })
      })
    )
    const input = wrapper.find('.fs-name-input')
    expect(input.exists()).toBe(true)
  })

  it('renames the placeholder when a name is committed', async () => {
    const { ctx, update, del } = makeCtx([])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await createFolder(wrapper)
    const input = wrapper.find('.fs-name-input')
    await input.setValue('Projects')
    await input.trigger('blur')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('new', {
      title: 'Projects',
      data: expect.objectContaining({ filename: 'Projects' })
    })
    expect(del).not.toHaveBeenCalled()
  })

  it('deletes the entry when the name is left empty', async () => {
    const { ctx, update, del } = makeCtx([])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await createFolder(wrapper)
    const input = wrapper.find('.fs-name-input')
    await input.setValue('')
    await input.trigger('blur')
    await flushPromises()

    expect(del).toHaveBeenCalledWith('new')
    expect(update).not.toHaveBeenCalled()
  })

  it('deletes the entry when naming is cancelled with Esc', async () => {
    const { ctx, del } = makeCtx([])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await createFolder(wrapper)
    const input = wrapper.find('.fs-name-input')
    await input.trigger('keydown', { key: 'Escape' })
    await input.trigger('blur')
    await flushPromises()

    expect(del).toHaveBeenCalledWith('new')
  })

  it('shows recursive contents and total size of a selected folder', async () => {
    // Docs/ holds one file and a Sub/ folder holding another file.
    const { ctx } = makeCtx([
      fileEntry('f1', 'Docs', { is_folder: true }),
      fileEntry('f2', 'Sub', { is_folder: true, parent_id: 'f1' }),
      fileEntry('a.pdf', 'a.pdf', { parent_id: 'f1', size: 1000 }),
      fileEntry('b.pdf', 'b.pdf', { parent_id: 'f2', size: 2000 }),
      fileEntry('out.pdf', 'out.pdf', { size: 9000 })
    ])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const docs = wrapper
      .findAll('.fs-row')
      .find(r => r.text().includes('Docs'))!
    await docs.trigger('click')
    await flushPromises()

    const meta = wrapper.find('.fs-detail-meta').text()
    // Nested file and folder counted, the sibling outside Docs left out.
    expect(meta).toContain('2 files, 1 folder')
    expect(meta).toContain('2.9 KB')
  })

  it('an empty rename of an existing folder does not delete it', async () => {
    const folder = fileEntry('f1', 'Docs', { is_folder: true })
    const { ctx, del, update } = makeCtx([folder])
    const wrapper = mount(FilesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.fs-name').trigger('dblclick')
    await flushPromises()
    const input = wrapper.find('.fs-name-input')
    await input.setValue('')
    await input.trigger('blur')
    await flushPromises()

    expect(del).not.toHaveBeenCalled()
    expect(update).not.toHaveBeenCalled()
  })
})
