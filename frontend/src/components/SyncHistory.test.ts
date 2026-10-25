import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, RouterLinkStub } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import SyncHistory from './SyncHistory.vue'

import { connectorLogDetails } from '../api/connectors'
import type { SyncLog } from '../types'

vi.mock('../api/connectors', () => ({ connectorLogDetails: vi.fn() }))

function run(overrides: Partial<SyncLog> = {}): SyncLog {
  return {
    id: 'run-1',
    status: 'completed',
    entries_count: 12,
    fetched_count: 152,
    known_count: 140,
    http_count: 37,
    http_failed_count: 2,
    log_count: 3,
    has_details: true,
    error: null,
    started_at: '2026-10-25T10:00:00Z',
    finished_at: '2026-10-25T10:00:03Z',
    ...overrides
  }
}

function mountHistory(logs: SyncLog[]) {
  return mount(SyncHistory, {
    props: { connectorId: 'source-1', logs },
    global: { stubs: { RouterLink: RouterLinkStub } }
  })
}

describe('SyncHistory', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(connectorLogDetails).mockReset()
  })

  it('sums up a run in one line', () => {
    const wrapper = mountHistory([run()])
    expect(wrapper.text()).toContain('12 new · 140 already known')
    expect(wrapper.text()).toContain('2 of 37 calls failed')
  })

  it('loads the details once and shows only the sections with content', async () => {
    vi.mocked(connectorLogDetails).mockResolvedValue({
      kinds: { bank_tx: 152 },
      new_entries: [{ id: 'e1', kind: 'bank_tx', title: 'Coffee' }],
      http: [],
      logs: []
    })
    const wrapper = mountHistory([run()])
    const toggle = wrapper.get('button[aria-expanded]')

    await toggle.trigger('click')
    await flushPromises()
    expect(toggle.attributes('aria-expanded')).toBe('true')
    expect(wrapper.text()).toContain('Coffee')
    expect(wrapper.text()).toContain('Bank transactions')
    expect(wrapper.text()).not.toContain('HTTP calls')

    await toggle.trigger('click')
    await toggle.trigger('click')
    await flushPromises()
    expect(connectorLogDetails).toHaveBeenCalledTimes(1)
  })

  it('says when a run kept no details', async () => {
    vi.mocked(connectorLogDetails).mockResolvedValue(null)
    const wrapper = mountHistory([run()])

    await wrapper.get('button[aria-expanded]').trigger('click')
    await flushPromises()
    expect(wrapper.text()).toContain(
      'Details are kept for the 50 most recent runs.'
    )
  })

  it('does not expand a running sync', () => {
    const wrapper = mountHistory([
      run({ status: 'running', finished_at: null })
    ])
    expect(wrapper.find('button[aria-expanded]').exists()).toBe(false)
  })
})
