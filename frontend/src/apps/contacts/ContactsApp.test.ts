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
    // selectContact and deleteContact change the URL through
    // history.replaceState. Reset the URL between tests so that a stray
    // "?selected=" does not leak.
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

    // The second removal stays in the queue behind the first save, which is
    // still pending.
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

    await wrapper.find('.ct-rel-type input').setValue('parent')
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

  it('accepts a custom relation type, normalized and symmetric', async () => {
    const alice = contact('a', 'Alice')
    const bob = contact('b', 'Bob')
    const { ctx, update } = makeCtx([alice, bob])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    await wrapper.find('.ct-rel-type input').setValue('  Climbing   Partner ')
    await wrapper.find('.ct-rel-name .cb-control').trigger('click')
    await wrapper
      .findAll('.ct-rel-name .cb-option')
      .find(o => o.text() === 'Bob')!
      .trigger('mousedown')
    await wrapper.find('.ct-rel-add').trigger('submit')
    await flushPromises()

    // This is not a built-in type. The app stores it as typed (normalized) on
    // the two sides.
    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({
        relations: [{ contact_id: 'b', type: 'climbing partner' }]
      })
    })
    expect(update).toHaveBeenCalledWith('b', {
      data: expect.objectContaining({
        relations: [{ contact_id: 'a', type: 'climbing partner' }]
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

    // saveForm awaits the tag save, which is still pending. Then it reads
    // selected.value.data again and sends the form PATCH.
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

  it('narrows the list with several tags at once', async () => {
    const contacts = [
      contact('a', 'Alice', { tags: ['family', 'paris'] }),
      contact('b', 'Bob', { tags: ['family'] }),
      contact('c', 'Carol', { tags: ['paris'] })
    ]
    const { ctx } = makeCtx(contacts)
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const chip = (name: string) =>
      wrapper.findAll('.ct-tag-chip').find(c => c.text() === name)!

    await chip('family').trigger('click')
    expect(wrapper.text()).toContain('Bob')

    // The two tags are active: only the contact that has the two tags stays.
    await chip('paris').trigger('click')
    const names = wrapper.findAll('.ct-card').map(c => c.text())
    expect(names.some(n => n.includes('Alice'))).toBe(true)
    expect(names.some(n => n.includes('Bob'))).toBe(false)
    expect(names.some(n => n.includes('Carol'))).toBe(false)

    // A click on an active chip releases only that tag.
    await chip('paris').trigger('click')
    expect(wrapper.findAll('.ct-card')).toHaveLength(2)
  })

  it('renames a tag on every contact carrying it', async () => {
    const contacts = [
      contact('a', 'Alice', { tags: ['famly', 'paris'] }),
      contact('b', 'Bob', { tags: ['famly'] }),
      contact('c', 'Carol', { tags: ['paris'] })
    ]
    const { ctx, update } = makeCtx(contacts)
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const chip = wrapper
      .findAll('.ct-tag-chip')
      .find(c => c.text() === 'famly')!
    await chip.trigger('dblclick')
    const input = wrapper.find('.ct-tag-rename')
    await input.setValue('  Family  ')
    await input.trigger('keyup.enter')
    await flushPromises()

    expect(update).toHaveBeenCalledWith('a', {
      data: expect.objectContaining({ tags: ['family', 'paris'] })
    })
    expect(update).toHaveBeenCalledWith('b', {
      data: expect.objectContaining({ tags: ['family'] })
    })
    // Carol never carried it.
    expect(update).not.toHaveBeenCalledWith('c', expect.anything())
  })

  it('previews the photos where the contact has a named face', async () => {
    const alice = contact('a', 'Alice')
    const photo = (id: string, thumb: string, personId: string): Entry => ({
      id,
      kind: 'photo',
      source: 'upload',
      external_id: null,
      title: id,
      occurred_at: null,
      data: {
        thumb_path: thumb,
        faces: [{ box: [0, 0, 1, 1], emb: [], person_id: personId }]
      },
      metadata: {},
      inserted_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z'
    })
    const { ctx } = makeCtx([alice])
    ctx.api.entries.list = vi.fn(async (filters?: Record<string, string>) => {
      if (filters?.kind === 'contact') return [alice]
      // The server-side q match is loose. The app filters on the exact id.
      if (filters?.kind === 'photo')
        return [
          photo('p1', '/files/t1.jpg', 'a'),
          photo('p2', '/f/t2.jpg', 'z')
        ]
      return []
    })
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await selectContact(wrapper, 'Alice')

    const thumbs = wrapper.findAll('.ct-photo')
    expect(thumbs).toHaveLength(1)
    expect(thumbs[0].attributes('href')).toBe('/photos/p1')
    expect(thumbs[0].find('img').attributes('src')).toBe('/files/t1.jpg')
    expect(wrapper.find('.ct-photo-all').attributes('href')).toBe(
      '/apps/photos?person=a'
    )
  })

  it('puts the graph and the creation form in the URL, and leaves them on a contact click', async () => {
    const { ctx } = makeCtx([contact('a', 'Alice')])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.ct-graph-btn').trigger('click')
    expect(window.location.search).toBe('?view=graph')
    expect(wrapper.findComponent({ name: 'RelationsGraph' }).exists()).toBe(
      true
    )

    await selectContact(wrapper, 'Alice')
    expect(window.location.search).toBe('?selected=a')
    expect(wrapper.findComponent({ name: 'RelationsGraph' }).exists()).toBe(
      false
    )

    await wrapper.find('.ct-add-contact-btn').trigger('click')
    expect(window.location.search).toBe('?view=new')
    await selectContact(wrapper, 'Alice')
    expect(window.location.search).toBe('?selected=a')
    expect(wrapper.find('.ct-form').exists()).toBe(false)
  })

  it('opens on the view named in the URL', async () => {
    window.history.replaceState(null, '', '/apps/contacts?view=graph')
    const { ctx } = makeCtx([contact('a', 'Alice')])
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()
    expect(wrapper.findComponent({ name: 'RelationsGraph' }).exists()).toBe(
      true
    )
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
    // The whole address book relates to me, so the section is only noise.
    const sections = wrapper.findAll('.ct-section-title').map(t => t.text())
    expect(sections).not.toContain('Relations')
  })

  it('lists duplicate groups and merges into the kept contact', async () => {
    const alice = contact('a', 'Alice', {
      emails: [{ value: 'alice@x.io', type: 'home' }]
    })
    const twin = contact('b', 'Alice Martin', {
      emails: [{ value: 'Alice@x.io', type: 'work' }],
      org: 'ACME'
    })
    const bob = contact('c', 'Bob')
    const contacts = [alice, twin, bob]
    const { ctx } = makeCtx(contacts)
    const merged = { ...twin, data: { ...twin.data, tags: ['x'] } }
    ctx.api.fetch = vi.fn(async () => {
      // Mirror the backend: the duplicate is gone and the survivor is updated.
      contacts.splice(0, contacts.length, merged, bob)
      return { ok: true, json: async () => ({ data: merged }) }
    }) as never
    const wrapper = mount(ContactsApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const button = wrapper.find('.ct-duplicates-btn')
    expect(button.text()).toBe('Duplicates (1)')
    await button.trigger('click')
    await flushPromises()

    const group = wrapper.find('.ct-dup-group')
    expect(group.find('.ct-dup-reasons').text()).toBe('same email, same name')
    // The app preselects the fuller card (org set) as the survivor.
    expect(group.find('.ct-dup-card--keep .ct-dup-name').text()).toBe(
      'Alice Martin'
    )
    // The two emails show. The app flags them as the value that the two cards
    // share.
    expect(
      group.findAll('.ct-dup-value--shared').map(value => value.text())
    ).toEqual(['alice@x.io', 'Alice@x.io'])

    await group.find('.ct-btn--primary').trigger('click')
    await flushPromises()

    expect(ctx.confirm.ask).toHaveBeenCalled()
    expect(ctx.api.fetch).toHaveBeenCalledWith(
      '/api/contacts/merge',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({ survivor_id: 'b', duplicate_ids: ['a'] })
      })
    )
    // The duplicate left the list, the survivor stayed, and the modal has no
    // group.
    const names = wrapper.findAll('.ct-card .ct-name').map(card => card.text())
    expect(names).toEqual(['Alice Martin', 'Bob'])
    expect(wrapper.find('.ct-dup-group').exists()).toBe(false)
  })
})
