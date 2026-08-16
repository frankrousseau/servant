import { afterEach, describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import TrackersApp from './TrackersApp.vue'

import type { Entry } from '../types'

function entry(kind: string, attrs: Partial<Entry> = {}): Entry {
  return {
    id: attrs.id || Math.random().toString(36).slice(2),
    kind,
    source: 'trackers_app',
    external_id: null,
    title: attrs.title ?? null,
    occurred_at: attrs.occurred_at ?? null,
    data: attrs.data || {},
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function makeCtx(trackers: Entry[], logs: Entry[] = []) {
  const create = vi.fn(async (attrs: Record<string, unknown>) =>
    entry(attrs.kind as string, {
      title: attrs.title as string,
      occurred_at: attrs.occurred_at as string,
      data: attrs.data as Record<string, unknown>
    })
  )
  const update = vi.fn(async (id: string, attrs: Record<string, unknown>) => ({
    ...logs.find(l => l.id === id)!,
    ...attrs
  }))
  const aggregate = vi.fn(async () => [] as { bucket: string; value: number }[])
  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async (filters?: Record<string, string>) =>
          filters?.kind === 'tracker' ? trackers : logs
        ),
        aggregate,
        create,
        update,
        delete: vi.fn()
      },
      upload: vi.fn(),
      fetch: vi.fn()
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
  return { ctx, create, update, aggregate }
}

describe('TrackersApp', () => {
  // The detail view seeds itself from ?tracker=; leave a clean URL behind.
  afterEach(() => {
    history.replaceState(null, '', '/')
  })

  it('renders trackers with their controls', async () => {
    const { ctx } = makeCtx([
      entry('tracker', { title: 'Guitare', data: { type: 'check' } }),
      entry('tracker', {
        title: 'Alcool',
        data: { type: 'count', unit: 'dose' }
      })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.text()).toContain('Guitare')
    expect(wrapper.text()).toContain('Alcool')
    expect(wrapper.find('.tk-toggle').exists()).toBe(true)
    expect(wrapper.findAll('.tk-step').length).toBeGreaterThan(0)
  })

  it('checking a check tracker creates a tracker_log for today', async () => {
    const { ctx, create } = makeCtx([
      entry('tracker', { id: 't1', title: 'Guitare', data: { type: 'check' } })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.tk-toggle').trigger('click')
    await flushPromises()

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'tracker_log',
        data: { tracker_id: 't1', value: 1 }
      })
    )
    expect(wrapper.find('.tk-toggle').text()).toContain('done')
  })

  it('incrementing a counter creates then updates the day log', async () => {
    const { ctx, create } = makeCtx([
      entry('tracker', {
        id: 't2',
        title: 'Alcool',
        data: { type: 'count', unit: 'dose' }
      })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const plus = wrapper.findAll('.tk-step')[1]
    await plus.trigger('click')
    await flushPromises()

    expect(create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'tracker_log',
        data: { tracker_id: 't2', value: 1 }
      })
    )
    expect(wrapper.find('.tk-count').text()).toContain('1')
  })

  it('clicking a tracker name opens the detail view and updates the URL', async () => {
    const { ctx } = makeCtx([
      entry('tracker', { id: 't1', title: 'Guitare', data: { type: 'check' } })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    await wrapper.find('.tk-name-btn').trigger('click')

    expect(wrapper.find('.tkd').exists()).toBe(true)
    expect(wrapper.find('.tk-grid').exists()).toBe(false)
    expect(window.location.search).toBe('?tracker=t1')

    await wrapper.find('.tkd-back').trigger('click')
    expect(wrapper.find('.tk-grid').exists()).toBe(true)
    expect(window.location.search).toBe('')
  })

  it('popstate drives the detail view like the browser back button', async () => {
    const { ctx } = makeCtx([
      entry('tracker', { id: 't1', title: 'Guitare', data: { type: 'check' } })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    history.replaceState(null, '', '/apps/trackers?tracker=t1')
    window.dispatchEvent(new PopStateEvent('popstate'))
    await flushPromises()
    expect(wrapper.find('.tkd').exists()).toBe(true)

    history.replaceState(null, '', '/apps/trackers')
    window.dispatchEvent(new PopStateEvent('popstate'))
    await flushPromises()
    expect(wrapper.find('.tk-grid').exists()).toBe(true)
  })

  it('a deep link with a stale tracker id falls back to the grid', async () => {
    history.replaceState(null, '', '/apps/trackers?tracker=gone')
    const { ctx } = makeCtx([
      entry('tracker', { id: 't1', title: 'Guitare', data: { type: 'check' } })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()

    expect(wrapper.find('.tkd').exists()).toBe(false)
    expect(wrapper.find('.tk-grid').exists()).toBe(true)
  })

  it('opening an entry tracker fetches week, month and year rollups', async () => {
    const { ctx, aggregate } = makeCtx([
      entry('tracker', {
        id: 't3',
        title: 'Commits',
        data: { type: 'entry', entry_kind: 'commit' }
      })
    ])
    const wrapper = mount(TrackersApp, { props: { ctx: ctx as never } })
    await flushPromises()
    aggregate.mockClear()

    await wrapper.find('.tk-name-btn').trigger('click')
    await flushPromises()

    const buckets = aggregate.mock.calls.map(
      call => (call as unknown as [Record<string, string>])[0].bucket
    )
    expect(buckets.sort()).toEqual(['month', 'week', 'year'])
    for (const call of aggregate.mock.calls) {
      const params = (call as unknown as [Record<string, string>])[0]
      expect(params.kind).toBe('commit')
      expect(params.from).toBeUndefined()
    }
  })
})
