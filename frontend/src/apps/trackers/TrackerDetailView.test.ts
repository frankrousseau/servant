import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import TrackerDetailView from './TrackerDetailView.vue'

import type { RollupPeriod, RollupRow, Tracker } from './trackers'

const TODAY = '2026-08-14'

function tracker(attrs: Partial<Tracker> = {}): Tracker {
  return {
    id: 't1',
    name: 'Guitare',
    type: 'check',
    unit: '',
    color: '#9d7bff',
    ...attrs
  }
}

function mountView(
  overrides: Partial<{
    tracker: Tracker
    byDate: Map<string, number>
    serverRollups: Record<RollupPeriod, RollupRow[]> | null
    serverState: 'idle' | 'loading' | 'error'
  }> = {}
) {
  return mount(TrackerDetailView, {
    props: {
      tracker: tracker(),
      byDate: new Map(),
      today: TODAY,
      serverRollups: null,
      serverState: 'idle' as const,
      ...overrides
    }
  })
}

describe('TrackerDetailView', () => {
  it('renders weekly rows for a check tracker as done days', () => {
    const wrapper = mountView({
      byDate: new Map([
        ['2026-08-10', 1],
        ['2026-08-11', 1],
        ['2026-08-12', 0]
      ])
    })

    expect(wrapper.find('[role="img"]').exists()).toBe(true)
    const cells = wrapper.findAll('.tkd-table tbody tr')
    expect(cells).toHaveLength(1)
    expect(cells[0].text()).toContain('Week of 2026-08-10')
    expect(cells[0].text()).toContain('2 days')
  })

  it('shows a dash for value-tracker periods without a measure', () => {
    const wrapper = mountView({
      tracker: tracker({ type: 'value', unit: 'kg', name: 'Poids' }),
      byDate: new Map([
        ['2026-07-27', 80],
        ['2026-07-29', 82],
        ['2026-08-10', 81]
      ])
    })

    const rows = wrapper.findAll('.tkd-table tbody tr')
    expect(rows).toHaveLength(3)
    // Newest first: the gap week is in the middle.
    expect(rows[0].text()).toContain('avg 81 kg (1 log)')
    expect(rows[1].text()).toContain('-')
    expect(rows[2].text()).toContain('avg 81 kg (2 logs)')
  })

  it('switches periods from the selector', async () => {
    const wrapper = mountView({
      byDate: new Map([
        ['2026-06-01', 1],
        ['2026-08-10', 1]
      ])
    })

    await wrapper
      .findAll('.tkd-period')
      .find(button => button.text() === 'Month')!
      .trigger('click')

    const rows = wrapper.findAll('.tkd-table tbody tr')
    expect(rows.map(row => row.text())).toEqual([
      expect.stringContaining('2026-08'),
      expect.stringContaining('2026-07'),
      expect.stringContaining('2026-06')
    ])
  })

  it('emits back from the back button', async () => {
    const wrapper = mountView({ byDate: new Map([['2026-08-10', 1]]) })
    await wrapper.find('.tkd-back').trigger('click')
    expect(wrapper.emitted('back')).toHaveLength(1)
  })

  it('renders entry trackers from server rollups and a loading state', () => {
    const loading = mountView({
      tracker: tracker({ type: 'entry', entryKind: 'commit', agg: 'count' }),
      serverState: 'loading'
    })
    expect(loading.text()).toContain('Loading history')

    const loaded = mountView({
      tracker: tracker({ type: 'entry', entryKind: 'commit', agg: 'count' }),
      serverRollups: {
        week: [{ bucket: '2026-08-10', value: 4, days: 1 }],
        month: [],
        year: []
      }
    })
    const rows = loaded.findAll('.tkd-table tbody tr')
    expect(rows).toHaveLength(1)
    expect(rows[0].text()).toContain('4')
  })

  it('shows inline values with few bars and titles only with many', () => {
    const few = mountView({
      byDate: new Map([
        ['2026-08-03', 1],
        ['2026-08-10', 1]
      ])
    })
    expect(few.findAll('.tkd-value').length).toBeGreaterThan(0)

    const byDate = new Map<string, number>()
    // One log for each week during 26 weeks: 2026-01-05 is a Monday.
    const start = Date.UTC(2026, 0, 5)
    for (let i = 0; i < 26; i++) {
      const date = new Date(start + i * 7 * 86_400_000)
        .toISOString()
        .slice(0, 10)
      byDate.set(date, 1)
    }
    const many = mountView({ byDate })
    // 26 weekly buckets: the slots are too narrow for inline numbers.
    expect(many.findAll('.tkd-table tbody tr').length).toBeGreaterThan(16)
    expect(many.findAll('.tkd-value')).toHaveLength(0)
  })

  it('shows the empty placeholder without data', () => {
    const wrapper = mountView()
    expect(wrapper.text()).toContain('No data yet.')
  })
})
