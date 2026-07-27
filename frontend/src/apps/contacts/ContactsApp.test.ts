import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import ContactsApp from './ContactsApp.vue'
import type { Entry } from '../types'

function contact(
  id: string,
  displayName: string,
  data: Record<string, unknown> = {}
): Entry {
  return {
    id,
    kind: 'contact',
    source: 'manual',
    external_id: null,
    title: displayName,
    occurred_at: null,
    data: { display_name: displayName, ...data },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(r => {
    resolve = r
  })
  return { promise, resolve }
}

function makeCtx(contacts: Entry[]) {
  const update = vi.fn(async (id: string, attrs: Record<string, unknown>) => ({
    ...contacts.find(c => c.id === id)!,
    ...attrs
  }))
  const create = vi.fn(async (attrs: Record<string, unknown>) => ({
    ...contact('new', 'New'),
    ...attrs
  }))
  const del = vi.fn(async () => {})
  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async (filters?: Record<string, string>) =>
          filters?.kind === 'contact' ? contacts : []
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
  return { ctx, update, create, del }
}

async function selectContact(wrapper: ReturnType<typeof mount>, name: string) {
  const card = wrapper.findAll('.ct-card').find(c => c.text().includes(name))!
  await card.trigger('click')
  await flushPromises()
}

describe('ContactsApp', () => {
  beforeEach(() => {
    // selectContact/deleteContact mutate the URL via history.replaceState;
    // reset between tests so a stray "?selected=" doesn't leak.
    window.history.replaceState(null, '', '/')
  })

  it('adds a tag and saves the normalized value', async () => {
    const alice = contact('a', 'Alice')
    const { ctx, update } = makeCtx([alice])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    const input = wrapper.find('.ct-tag-add input')
    await input.setValue('  Family  ')
    await input.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({ tags: ['family'] })
    })
  })

  it('clicking a suggestion adds the tag immediately', async () => {
    const alice = contact('a', 'Alice')
    const bob = contact('b', 'Bob', { tags: ['family'] })
    const { ctx, update } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    await wrapper.find('.ct-tag-add input').trigger('focus')
    const option = wrapper
      .findAll('.ct-tag-add .ac-option')
      .find(o => o.text() === 'family')
    expect(option).toBeTruthy()
    await option!.trigger('mousedown')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({ tags: ['family'] })
    })
  })

  it('serializes queued tag saves: the second PATCH derives from the first result', async () => {
    const alice = contact('a', 'Alice', { tags: ['a', 'b'] })
    const { ctx, update } = makeCtx([alice])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    const d1 = deferred<Entry>()
    const d2 = deferred<Entry>()
    update.mockImplementationOnce(() => d1.promise)
    update.mockImplementationOnce(() => d2.promise)

    const chips = wrapper.findAll('.ct-tag-x')
    expect(chips).toHaveLength(2)
    await chips[0].trigger('click')
    await chips[1].trigger('click')
    await flushPromises()

    // The second removal is queued behind the first, still-pending save.
    expect(update).toHaveBeenCalledTimes(1)
    const firstBody = update.mock.calls[0][1] as { data: { tags: string[] } }
    expect(firstBody.data.tags).toEqual(['b'])

    d1.resolve({ ...alice, data: { ...alice.data, tags: firstBody.data.tags } })
    await flushPromises()

    expect(update).toHaveBeenCalledTimes(2)
    const secondBody = update.mock.calls[1][1] as { data: { tags: string[] } }
    expect(secondBody.data.tags).toEqual([])

    d2.resolve({
      ...alice,
      data: { ...alice.data, tags: secondBody.data.tags }
    })
    await flushPromises()
  })

  it('adds a reciprocal relation with the inverse type on the target', async () => {
    const alice = contact('a', 'Alice')
    const bob = contact('b', 'Bob')
    const { ctx, update } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    await wrapper.find('.ct-rel-type .cb-control').trigger('click')
    await wrapper
      .findAll('.ct-rel-type .cb-option')
      .find(o => o.text() === 'Parent')!
      .trigger('mousedown')
    await wrapper.find('.ct-rel-name .cb-control').trigger('click')
    await wrapper
      .findAll('.ct-rel-name .cb-option')
      .find(o => o.text() === 'Bob')!
      .trigger('mousedown')
    await wrapper.find('.ct-rel-add').trigger('submit')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({
        relations: [{ contact_id: 'b', type: 'parent' }]
      })
    })
    expect(update).toHaveBeenCalledWith('b', {
      data: expect.objectContaining({
        relations: [{ contact_id: 'a', type: 'child' }]
      })
    })
  })

  it('removes a relation from either side, dropping both directions', async () => {
    const alice = contact('a', 'Alice', {
      relations: [{ contact_id: 'b', type: 'parent' }]
    })
    const bob = contact('b', 'Bob', {
      relations: [{ contact_id: 'a', type: 'child' }]
    })
    const { ctx, update } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    await wrapper.find('.ct-rel-x').trigger('click')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({ relations: [] })
    })
    expect(update).toHaveBeenCalledWith('b', {
      data: expect.objectContaining({ relations: [] })
    })
  })

  it('drops the relation on the other contact when the target is deleted', async () => {
    const alice = contact('a', 'Alice', {
      relations: [{ contact_id: 'b', type: 'friend' }]
    })
    const bob = contact('b', 'Bob')
    const { ctx, update, del } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Bob')

    await wrapper.find('.ct-footer-btn--danger').trigger('click')
    await flushPromises()

    expect(del).toHaveBeenCalledWith('b')
    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({ relations: [] })
    })
  })

  it('drains queued tag saves before the edit-form PATCH re-reads state', async () => {
    const alice = contact('a', 'Alice')
    const { ctx, update } = makeCtx([alice])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    const d1 = deferred<Entry>()
    update.mockImplementationOnce(() => d1.promise)

    const tagInput = wrapper.find('.ct-tag-add input')
    await tagInput.setValue('urgent')
    await tagInput.trigger('keydown', { key: 'Enter' })
    expect(update).toHaveBeenCalledTimes(1)

    await wrapper.find('.ct-header-edit').trigger('click')
    await flushPromises()
    expect(wrapper.find('.ct-form-title').text()).toBe('Edit contact')

    // saveForm awaits the still-pending tag save before it re-reads
    // selected.value.data and issues the form PATCH.
    await wrapper.find('.ct-form').trigger('submit')
    expect(update).toHaveBeenCalledTimes(1)

    d1.resolve({ ...alice, data: { ...alice.data, tags: ['urgent'] } })
    await flushPromises()

    expect(update).toHaveBeenCalledTimes(2)
    const formBody = update.mock.calls[1][1] as { data: { tags: string[] } }
    expect(formBody.data.tags).toEqual(['urgent'])
  })

  it('keeps the edit-form PATCH on the contact captured at submit if selection moves mid-drain', async () => {
    const alice = contact('a', 'Alice')
    const bob = contact('b', 'Bob')
    const { ctx, update } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    const d1 = deferred<Entry>()
    update.mockImplementationOnce(() => d1.promise)

    const tagInput = wrapper.find('.ct-tag-add input')
    await tagInput.setValue('urgent')
    await tagInput.trigger('keydown', { key: 'Enter' })

    await wrapper.find('.ct-header-edit').trigger('click')
    await flushPromises()
    await wrapper.find('.ct-form input[required]').setValue('Alice Renamed')
    await wrapper.find('.ct-form').trigger('submit')
    expect(update).toHaveBeenCalledTimes(1)

    // The user clicks Bob while the drain is still pending: the form PATCH
    // must still target Alice, not the new selection.
    await selectContact(wrapper, 'Bob')

    d1.resolve({ ...alice, data: { ...alice.data, tags: ['urgent'] } })
    await flushPromises()

    expect(update).toHaveBeenCalledTimes(2)
    expect(update.mock.calls[1][0]).toBe('a')
    const formBody = update.mock.calls[1][1] as {
      data: { display_name: string; tags: string[] }
    }
    expect(formBody.data.display_name).toBe('Alice Renamed')
    expect(formBody.data.tags).toEqual(['urgent'])
  })

  it('marks a contact as me via a singleton prefs entry', async () => {
    const alice = contact('a', 'Alice')
    const { ctx, create } = makeCtx([alice])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    await wrapper.find('.ct-dash-toggle input').setValue(true)
    await flushPromises()

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'prefs',
        title: 'me',
        data: { contact_id: 'a' }
      })
    )
    expect(wrapper.find('.ct-me-badge').exists()).toBe(true)
    // The whole address book relates to me: the section would only be noise.
    const sections = wrapper.findAll('.ct-section-title').map(t => t.text())
    expect(sections).not.toContain('Relations')
  })
})
