import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import NotesApp from './NotesApp.vue'

import { fakePreferences } from '../fakePreferences'
import type { Entry } from '../types'

function note(id: string, title: string, folder: string, body: string): Entry {
  return {
    id,
    kind: 'note',
    source: 'notes',
    external_id: null,
    title,
    occurred_at: null,
    data: { folder, body, tags: [] },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function makeCtx(notes: Entry[]) {
  const jsonRes = (data: unknown) =>
    ({ json: async () => ({ data }) }) as Response
  const update = vi.fn(
    async (_id: string, attrs: Record<string, unknown>) => attrs
  )

  const fetchMock = vi.fn(async (path: string, opts?: RequestInit) => {
    if (path === '/api/notes' && (!opts || opts.method === undefined))
      return jsonRes(notes)
    if (path.endsWith('/backlinks')) return jsonRes([])
    if (path === '/api/notes' && opts?.method === 'POST') {
      const attrs = JSON.parse(opts.body as string)
      return jsonRes(note('new', attrs.title, attrs.folder, attrs.body))
    }
    if (opts?.method === 'PUT') {
      const id = path.split('/').pop()!
      const attrs = JSON.parse(opts.body as string)
      await update(id, attrs)
      // Mirror the backend: absent fields keep their current value.
      const found = notes.find(n => n.id === id)!
      return jsonRes({
        ...found,
        title: attrs.title ?? found.title,
        data: {
          ...found.data,
          ...(attrs.favorite === undefined ? {} : { favorite: attrs.favorite }),
          ...(attrs.attachments === undefined
            ? {}
            : { attachments: attrs.attachments })
        }
      })
    }
    return jsonRes([])
  })

  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    preferences: fakePreferences(),
    api: {
      entries: { list: vi.fn().mockResolvedValue([]) },
      upload: vi.fn(),
      fetch: fetchMock
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
  return { ctx, fetchMock, update }
}

describe('NotesApp', () => {
  beforeEach(() => {
    // Selection pushes ?selected=<id>; keep tests URL-independent.
    history.replaceState(null, '', '/apps/notes')
  })

  it('loads the note tree (folders + notes)', async () => {
    const { ctx } = makeCtx([
      note('1', 'Alpha', '', 'hello'),
      note('2', 'Beta', 'Proj', '')
    ])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.text()).toContain('Alpha')
    expect(wrapper.text()).toContain('Beta')
    expect(wrapper.text()).toContain('Proj') // folder row
  })

  it('collapses and expands every folder from the sidebar toggle', async () => {
    const { ctx } = makeCtx([
      note('1', 'Alpha', 'Proj', ''),
      note('2', 'Beta', 'Proj/Sub', ''),
      note('3', 'Root', '', '')
    ])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const titles = () =>
      wrapper.findAll('.nt-note-title').map(title => title.text())
    expect(titles()).toContain('Alpha')

    await wrapper.find('.nt-tree-toggle').trigger('click')
    // Folder rows survive, notes inside collapsed folders do not.
    expect(wrapper.text()).toContain('Proj')
    expect(titles()).not.toContain('Alpha')
    expect(titles()).not.toContain('Beta')
    expect(titles()).toContain('Root')

    await wrapper.find('.nt-tree-toggle').trigger('click')
    expect(titles()).toContain('Alpha')
    expect(titles()).toContain('Beta')
  })

  it('selecting a note fills the editor and resolves a known wikilink in preview', async () => {
    const { ctx } = makeCtx([
      note('1', 'Alpha', '', 'see [[Beta]]'),
      note('2', 'Beta', '', '')
    ])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    // Click the "Alpha" note row.
    const alpha = wrapper
      .findAll('.nt-note')
      .find(n => n.text().includes('Alpha'))!
    await alpha.trigger('click')
    await flushPromises()

    const body = wrapper.find('textarea.nt-body').element as HTMLTextAreaElement
    expect(body.value).toBe('see [[Beta]]')
    expect(
      (wrapper.find('input.nt-title').element as HTMLInputElement).value
    ).toBe('Alpha')

    // Beta exists, so its wikilink is resolved (not flagged --new).
    const preview = wrapper.find('.nt-preview')
    expect(preview.html()).toContain('nt-wikilink')
    expect(preview.html()).not.toContain('nt-wikilink--new')
  })

  it('renders note rows as links so they open in a new tab', async () => {
    const { ctx } = makeCtx([note('1', 'Alpha', '', '')])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const row = wrapper.find('.nt-note')
    expect(row.element.tagName).toBe('A')
    expect(row.attributes('href')).toBe('/apps/notes?selected=1')

    // A modified click is left to the browser: no in-app selection.
    await row.trigger('click', { ctrlKey: true })
    await flushPromises()
    expect(wrapper.find('input.nt-title').exists()).toBe(false)
  })

  it('editing the body triggers a debounced save', async () => {
    vi.useFakeTimers()
    const { ctx, update } = makeCtx([note('1', 'Alpha', '', 'x')])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await vi.runAllTimersAsync()

    const alpha = wrapper
      .findAll('.nt-note')
      .find(n => n.text().includes('Alpha'))!
    await alpha.trigger('click')
    await vi.runAllTimersAsync()

    const body = wrapper.find('textarea.nt-body')
    await body.setValue('x edited')
    await vi.advanceTimersByTimeAsync(700)
    await vi.runAllTimersAsync()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({ body: 'x edited' })
    )
    vi.useRealTimers()
  })

  it('keeps what was typed while a save was in flight', async () => {
    const note1 = note('1', 'Alpha', '', 'x')
    let releasePut: (() => void) | undefined
    const putBodies: string[] = []

    const jsonRes = (data: unknown) =>
      ({ json: async () => ({ data }) }) as Response

    const ctx = {
      navigate: vi.fn(),
      confirm: { ask: vi.fn().mockResolvedValue(true) },
      preferences: fakePreferences(),
      api: {
        entries: { list: vi.fn().mockResolvedValue([]) },
        upload: vi.fn(),
        fetch: vi.fn(async (path: string, opts?: RequestInit) => {
          if (path === '/api/notes' && !opts?.method) return jsonRes([note1])
          if (path.endsWith('/backlinks')) return jsonRes([])
          if (opts?.method === 'PUT') {
            const attrs = JSON.parse(opts.body as string)
            putBodies.push(attrs.body)
            // Hold the response so the user can keep typing meanwhile.
            await new Promise<void>(resolve => {
              releasePut = resolve
            })
            return jsonRes({ ...note1, data: { ...note1.data, ...attrs } })
          }
          return jsonRes([])
        })
      },
      viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
    }

    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.find('.nt-note').trigger('click')
    await flushPromises()

    const body = wrapper.find('textarea.nt-body')
    await body.setValue('x1')
    await new Promise(r => setTimeout(r, 650)) // debounce
    await flushPromises()
    expect(putBodies).toEqual(['x1'])

    // Still typing while the server has the previous version.
    await body.setValue('x12')
    releasePut!()
    await flushPromises()

    // The reply must not roll the editor back to what it echoed.
    expect((body.element as HTMLTextAreaElement).value).toBe('x12')
  })

  it('renames a folder across all its notes (children included)', async () => {
    const { ctx, update } = makeCtx([
      note('1', 'Alpha', 'Proj', ''),
      note('2', 'Beta', 'Proj/Sub', ''),
      note('3', 'Gamma', '', '')
    ])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    // Rename the top-level "Proj" folder (first pencil in the tree).
    await wrapper.find('.nt-folder-edit').trigger('click')
    const input = wrapper.find('.nt-folder-rename')
    await input.setValue('Projects')
    await input.trigger('keyup.enter')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({ folder: 'Projects' })
    )
    expect(update).toHaveBeenCalledWith(
      '2',
      expect.objectContaining({ folder: 'Projects/Sub' })
    )
    expect(update).not.toHaveBeenCalledWith('3', expect.anything())
  })

  it('creates a note inside a folder from its + button', async () => {
    const { ctx, fetchMock } = makeCtx([note('1', 'Alpha', 'Proj', '')])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.nt-folder-add').trigger('click')
    await flushPromises()

    const post = fetchMock.mock.calls.find(
      ([path, opts]) => path === '/api/notes' && opts?.method === 'POST'
    )
    expect(JSON.parse(post![1]!.body as string)).toMatchObject({
      folder: 'Proj'
    })
  })

  it('pins favorite notes above the tree', async () => {
    const fav = note('1', 'Alpha', 'Proj', '')
    fav.data.favorite = true
    const { ctx } = makeCtx([fav, note('2', 'Beta', '', '')])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.find('.nt-fav-head').text()).toBe('Favorites')
    const favRow = wrapper.find('.nt-note--fav')
    expect(favRow.text()).toContain('Alpha')
    // The note keeps its place in the folder tree too.
    expect(
      wrapper.findAll('.nt-note').filter(n => n.text().includes('Alpha')).length
    ).toBe(2)
  })

  it('toggles favorite from the editor toolbar', async () => {
    const { ctx, update } = makeCtx([note('1', 'Alpha', '', '')])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.nt-note').trigger('click')
    await flushPromises()
    expect(wrapper.find('.nt-fav-head').exists()).toBe(false)

    await wrapper.find('.nt-fav-btn').trigger('click')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('1', { favorite: true })
    expect(wrapper.find('.nt-fav-head').exists()).toBe(true)
  })

  it('reopens the last open note on mount', async () => {
    const { ctx } = makeCtx([
      note('1', 'Alpha', '', ''),
      note('2', 'Beta', '', '')
    ])
    ctx.preferences.set('notes.lastOpen', '2')
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(
      (wrapper.find('input.nt-title').element as HTMLInputElement).value
    ).toBe('Beta')
  })

  it('moves a note into a folder via drag & drop', async () => {
    const { ctx, update } = makeCtx([
      note('1', 'Alpha', '', ''),
      note('2', 'Beta', 'Proj', '')
    ])
    const wrapper = mount(NotesApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const alpha = wrapper
      .findAll('.nt-note')
      .find(n => n.text().includes('Alpha'))!
    await alpha.trigger('dragstart')
    await wrapper.find('.nt-folder').trigger('drop')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({ folder: 'Proj' })
    )
  })

  it('attaches a Files entry to the note and detaches it', async () => {
    const { ctx, update } = makeCtx([note('1', 'Alpha', '', '')])
    ctx.api.entries.list = vi.fn(async () => [
      {
        ...note('f1', 'bail.txt', '', ''),
        kind: 'file',
        data: { filename: 'bail.txt', path: '/files/u/bail.txt' }
      },
      {
        ...note('f2', 'Admin', '', ''),
        kind: 'file',
        data: { filename: 'Admin', is_folder: true }
      }
    ])
    const wrapper = mount(NotesApp, {
      props: { ctx: ctx as never },
      global: { stubs: { teleport: true } }
    })
    await flushPromises()

    await wrapper
      .findAll('.nt-note')
      .find(row => row.text().includes('Alpha'))!
      .trigger('click')
    await flushPromises()

    await wrapper.find('.nt-attach-btn').trigger('click')
    await flushPromises()

    // Folders are not attachable; the file is.
    const options = wrapper.findAll('.nt-attach-option')
    expect(options.map(option => option.text())).toEqual(['bail.txt'])
    await options[0].trigger('click')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({ attachments: ['f1'] })
    )
    const chip = wrapper.find('.nt-attachment')
    expect(chip.text()).toContain('bail.txt')
    expect(chip.find('a').attributes('href')).toBe('/files/u/bail.txt')

    await wrapper.find('.nt-attachment-remove').trigger('click')
    await flushPromises()
    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({ attachments: [] })
    )
    expect(wrapper.find('.nt-attachment').exists()).toBe(false)
  })
})
