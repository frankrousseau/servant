import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import ChecklistsApp from './ChecklistsApp.vue'
import type { Entry } from '../types'

interface Item {
  text: string
  done: boolean
}

function checklist(
  id: string,
  title: string,
  folder: string,
  recurring: boolean,
  items: Item[]
): Entry {
  return {
    id,
    kind: 'checklist',
    source: 'manual',
    external_id: null,
    title,
    occurred_at: null,
    data: { folder, recurring, items },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function orderEntry(app: string, folders: string[]): Entry {
  return {
    id: 'order-' + app,
    kind: 'folder_order',
    source: 'manual',
    external_id: null,
    title: app,
    occurred_at: null,
    data: { folders },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function makeCtx(checklists: Entry[], orderEntries: Entry[] = []) {
  const update = vi.fn(async (id: string, attrs: Record<string, unknown>) => ({
    ...checklists.find(c => c.id === id)!,
    ...attrs
  }))
  const create = vi.fn(async (attrs: Record<string, unknown>) => ({
    ...orderEntry('x', []),
    ...attrs
  }))
  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async (filters?: Record<string, string>) =>
          filters?.kind === 'folder_order' ? orderEntries : checklists
        ),
        update,
        create,
        delete: vi.fn()
      },
      upload: vi.fn(),
      fetch: vi.fn()
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
  return { ctx, update, create }
}

async function selectList(wrapper: ReturnType<typeof mount>, title: string) {
  const row = wrapper.findAll('.cl-row').find(r => r.text().includes(title))!
  await row.trigger('click')
  await flushPromises()
}

describe('ChecklistsApp', () => {
  it('loads the tree with folder groups and done counts', async () => {
    const { ctx } = makeCtx([
      checklist('1', 'Courses', '', false, [
        { text: 'Lait', done: true },
        { text: 'Pain', done: false }
      ]),
      checklist('2', 'Valise', 'Voyages', true, [])
    ])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.text()).toContain('Courses')
    expect(wrapper.text()).toContain('Voyages') // folder row
    expect(wrapper.text()).toContain('Valise')
    expect(wrapper.text()).toContain('1/2') // done count on Courses
  })

  it('reset unchecks every item and saves; only recurring lists show the button', async () => {
    const { ctx, update } = makeCtx([
      checklist('1', 'Routine', '', true, [
        { text: 'a', done: true },
        { text: 'b', done: true }
      ]),
      checklist('2', 'One-shot', '', false, [{ text: 'c', done: true }])
    ])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await selectList(wrapper, 'One-shot')
    expect(wrapper.find('.cl-reset-btn').exists()).toBe(false)

    await selectList(wrapper, 'Routine')
    const reset = wrapper.find('.cl-reset-btn')
    expect(reset.exists()).toBe(true)
    await reset.trigger('click')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({
        data: expect.objectContaining({
          items: [
            { text: 'a', done: false },
            { text: 'b', done: false }
          ]
        })
      })
    )
    expect(wrapper.text()).toContain('0/2')
  })

  it('renames a folder across all its lists', async () => {
    const { ctx, update } = makeCtx([
      checklist('1', 'Valise', 'Voyages', false, []),
      checklist('2', 'Camping', 'Voyages', false, []),
      checklist('3', 'Courses', '', false, [])
    ])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.cl-folder-edit').trigger('click')
    const input = wrapper.find('.cl-folder-rename')
    await input.setValue('Trips')
    await input.trigger('keyup.enter')
    await flushPromises()

    const folderArg = expect.objectContaining({
      data: expect.objectContaining({ folder: 'Trips' })
    })
    expect(update).toHaveBeenCalledWith('1', folderArg)
    expect(update).toHaveBeenCalledWith('2', folderArg)
    expect(update).not.toHaveBeenCalledWith('3', expect.anything())
    expect(wrapper.text()).toContain('Trips')
    expect(wrapper.text()).not.toContain('Voyages')
  })

  it('applies the persisted folder order', async () => {
    const { ctx } = makeCtx(
      [
        checklist('1', 'A', 'Autres', false, []),
        checklist('2', 'B', 'Voyages', false, [])
      ],
      [orderEntry('checklists', ['Voyages', 'Autres'])]
    )
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const names = wrapper.findAll('.cl-folder-name').map(f => f.text())
    expect(names).toEqual(['Voyages', 'Autres'])
  })

  it('reorders folders by drag & drop and persists the order', async () => {
    const { ctx, create } = makeCtx([
      checklist('1', 'A', 'Autres', false, []),
      checklist('2', 'B', 'Voyages', false, [])
    ])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const folderRow = (name: string) =>
      wrapper.findAll('.cl-folder').find(f => f.text().includes(name))!
    await folderRow('Voyages').trigger('dragstart')
    await folderRow('Autres').trigger('drop')
    await flushPromises()

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'folder_order',
        title: 'checklists',
        data: { folders: ['Voyages', 'Autres'] }
      })
    )
    const names = wrapper.findAll('.cl-folder-name').map(f => f.text())
    expect(names).toEqual(['Voyages', 'Autres'])
  })

  it('moves a list into a folder via drag & drop', async () => {
    const { ctx, update } = makeCtx([
      checklist('1', 'Courses', '', false, []),
      checklist('2', 'Valise', 'Voyages', false, [])
    ])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const row = wrapper
      .findAll('.cl-row')
      .find(r => r.text().includes('Courses'))!
    await row.trigger('dragstart')
    await wrapper.find('.cl-folder').trigger('drop')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({
        data: expect.objectContaining({ folder: 'Voyages' })
      })
    )
  })

  it('adds an item and saves immediately', async () => {
    const { ctx, update } = makeCtx([checklist('1', 'Courses', '', false, [])])
    const wrapper = mount(ChecklistsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await selectList(wrapper, 'Courses')
    await wrapper.find('.cl-add-input').setValue('Beurre')
    await wrapper.find('.cl-add').trigger('submit')
    await flushPromises()

    expect(update).toHaveBeenCalledWith(
      '1',
      expect.objectContaining({
        data: expect.objectContaining({
          items: [{ text: 'Beurre', done: false }]
        })
      })
    )
    const itemInput = wrapper.find('.cl-item-text').element as HTMLInputElement
    expect(itemInput.value).toBe('Beurre')
  })
})
