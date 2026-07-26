import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import NotesApp from './NotesApp.vue'
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
          ...(attrs.favorite === undefined ? {} : { favorite: attrs.favorite })
        }
      })
    }
    return jsonRes([])
  })

  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
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
    localStorage.clear()
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
    localStorage.setItem('servant_notes_last_open', '2')
    const { ctx } = makeCtx([
      note('1', 'Alpha', '', ''),
      note('2', 'Beta', '', '')
    ])
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
})
