import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import LoadState from './LoadState.vue'

import type { LoadStatus } from './LoadState.vue'

function mountState(
  props: { state: LoadStatus } & Record<string, unknown>,
  slots = {}
) {
  return mount(LoadState, {
    props: { what: 'notes', ...props },
    slots: { default: '<ul class="list">Notes</ul>', ...slots }
  })
}

describe('LoadState', () => {
  it('announces loading as a status', () => {
    const line = mountState({ state: 'loading' }).find('[role="status"]')
    expect(line.text()).toBe('Loading notes…')
  })

  it('announces an error as an alert, with Retry when asked', async () => {
    const plain = mountState({ state: 'error' })
    expect(plain.find('[role="alert"]').text()).toBe('Failed to load notes.')
    expect(plain.find('button').exists()).toBe(false)

    const retryable = mountState({ state: 'error', retryable: true })
    await retryable.find('button').trigger('click')
    expect(retryable.emitted('retry')).toHaveLength(1)
  })

  it('shows the empty line, the #empty slot, or the content', () => {
    expect(mountState({ state: 'ready', empty: true }).text()).toBe(
      'No notes yet.'
    )

    const custom = mountState(
      { state: 'ready', empty: true },
      { empty: '<p>Write your first note</p>' }
    )
    expect(custom.text()).toBe('Write your first note')

    const ready = mountState({ state: 'ready' })
    expect(ready.find('.list').exists()).toBe(true)
  })

  it('takes custom texts', () => {
    expect(
      mountState({ state: 'loading', loadingText: 'Reading directory…' }).text()
    ).toBe('Reading directory…')
    expect(
      mountState({ state: 'ready', empty: true, emptyText: 'No match.' }).text()
    ).toBe('No match.')
  })
})
