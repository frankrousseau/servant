import { describe, it, expect, beforeEach } from 'vitest'
import { reactive } from 'vue'
import { mount } from '@vue/test-utils'

import SpendingView from './SpendingView.vue'

import type { AppContext, Entry } from '../types'

function tx(
  date: string,
  amount: number,
  category?: string,
  account = 'N26'
): Entry {
  return {
    id: Math.random().toString(36).slice(2),
    kind: 'bank_tx',
    source: 'test',
    external_id: null,
    title: null,
    occurred_at: `${date}T12:00:00Z`,
    data: {
      account,
      amount,
      currency: 'EUR',
      ...(category ? { category } : {})
    },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

const TXS = [
  tx('2026-06-10', -40, 'food'),
  tx('2026-06-15', -150, 'rent'),
  tx('2026-07-02', -60, 'food')
]

// This is a substitute for the account-backed preferences. The mounts share
// it.
let prefs: Record<string, unknown> = reactive({})
const ctx = {
  preferences: {
    get: <T>(key: string, fallback: T) => (prefs[key] as T) ?? fallback,
    set: (key: string, value: unknown) => {
      prefs[key] = value
    }
  }
} as unknown as AppContext

function mountView(txs = TXS) {
  return mount(SpendingView, {
    props: { ctx, txs, accounts: [], rates: {}, refCurrency: 'EUR' }
  })
}

describe('SpendingView', () => {
  beforeEach(() => {
    prefs = reactive({})
  })

  it('shows a legend chip per category, largest total first', () => {
    const wrapper = mountView()
    const chips = wrapper.findAll('.sp-chip').map(c => c.text())
    expect(chips).toEqual(['rent', 'food'])
  })

  it('hides a clicked category from chart and table, persisted', async () => {
    const wrapper = mountView()
    await wrapper.findAll('.sp-chip')[0].trigger('click')
    const cats = wrapper.findAll('tbody .sp-cat-col').map(c => c.text())
    expect(cats).toEqual(['food'])
    expect(prefs['finance.hiddenCategories']).toEqual(['rent'])
    // A fresh mount reads the exclusion back.
    const again = mountView()
    const cats2 = again.findAll('tbody .sp-cat-col').map(c => c.text())
    expect(cats2).toEqual(['food'])
  })

  it('solos a category on double-click and reverts on the second', async () => {
    const wrapper = mountView()
    await wrapper.findAll('.sp-chip')[1].trigger('dblclick')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'food'
    ])
    await wrapper.findAll('.sp-chip')[1].trigger('dblclick')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'rent',
      'food'
    ])
  })

  it('aggregates by year and scopes to one year', async () => {
    const wrapper = mountView([...TXS, tx('2025-03-05', -200, 'rent')])
    const range = wrapper.findAllComponents({ name: 'ComboBox' }).at(-1)!
    expect(range.props('options')).toEqual([
      'Last 3 months',
      'Last 12 months',
      '2026',
      '2025',
      'All years'
    ])

    await range.vm.$emit('update:modelValue', 'All years')
    let headers = wrapper.findAll('thead th').map(h => h.text())
    expect(headers).toEqual(['Category', '2025', '2026', 'Total ▼'])
    const rentCells = wrapper
      .findAll('tbody tr')
      .find(r => r.text().includes('rent'))!
      .findAll('td')
      .map(c => c.text())
    expect(rentCells.slice(1)).toEqual(['200 EUR', '150 EUR', '350 EUR'])

    await range.vm.$emit('update:modelValue', '2025')
    headers = wrapper.findAll('thead th').map(h => h.text())
    expect(headers).toEqual(['Category', '2025-03', 'Total ▼'])
  })

  it('scopes to the last three spending months', async () => {
    const wrapper = mountView([
      ...TXS,
      tx('2026-03-05', -50, 'rent'),
      tx('2026-04-02', -70, 'food')
    ])
    const range = wrapper.findAllComponents({ name: 'ComboBox' }).at(-1)!
    await range.vm.$emit('update:modelValue', 'Last 3 months')

    const headers = wrapper.findAll('thead th').map(header => header.text())
    expect(headers).toEqual([
      'Category',
      '2026-04',
      '2026-06',
      '2026-07',
      'Total ▼'
    ])
  })

  it('shows a pie for the chosen period', async () => {
    const wrapper = mountView()
    const chartType = wrapper.findAllComponents({ name: 'ComboBox' }).at(0)!
    await chartType.vm.$emit('update:modelValue', 'Pie')
    // The default is the most recent month. In 2026-07, the only spending is
    // food.
    expect(wrapper.findAll('.sp-pie path').length).toBe(1)
    expect(wrapper.find('.sp-pie-period').text()).toBe('2026-07')

    const period = wrapper.findAllComponents({ name: 'ComboBox' }).at(1)!
    await period.vm.$emit('update:modelValue', '2026-06')
    const rows = wrapper.findAll('.sp-breakdown-row').map(r => r.text())
    expect(wrapper.findAll('.sp-pie path').length).toBe(2)
    expect(rows[0]).toContain('rent')
    expect(rows[0]).toContain('79%')
    expect(rows[1]).toContain('food')
    expect(rows[1]).toContain('21%')
  })

  it('reads the hovered column, then the hovered slice inside it', async () => {
    const wrapper = mountView()
    // There is one hit area for each period in range: June and July 2026.
    const columns = wrapper.findAll('.sp-hit')
    expect(columns.length).toBe(2)

    await columns[0].trigger('pointerenter')
    const readout = wrapper.find('.sp-readout')
    expect(readout.find('.sp-readout-total').text()).toBe('190 EUR')
    expect(readout.findAll('.sp-readout-row').map(row => row.text())).toEqual([
      'rent150 EUR79%',
      'food40 EUR21%'
    ])
    // The readout calls out nothing until the pointer is on a slice.
    expect(readout.find('.sp-readout-row--on').exists()).toBe(false)

    await wrapper
      .findAll('.sp-col')[0]
      .findAll('.sp-slice')[1]
      .trigger('pointerenter')
    expect(wrapper.find('.sp-readout-row--on').text()).toContain('food')

    await wrapper.find('.sp-chart').trigger('pointerleave')
    expect(wrapper.find('.sp-readout').exists()).toBe(false)
  })

  it('swaps the donut center for the hovered category', async () => {
    const wrapper = mountView()
    const chartType = wrapper.findAllComponents({ name: 'ComboBox' }).at(0)!
    await chartType.vm.$emit('update:modelValue', 'Pie')
    const period = wrapper.findAllComponents({ name: 'ComboBox' }).at(1)!
    await period.vm.$emit('update:modelValue', '2026-06')

    expect(wrapper.find('.sp-pie-total').text()).toBe('190 EUR')
    await wrapper.findAll('.sp-pie .sp-slice')[1].trigger('pointerenter')
    expect(wrapper.find('.sp-pie-total').text()).toBe('40 EUR')
    expect(wrapper.find('.sp-pie-period').text()).toBe('food · 21%')
    expect(wrapper.find('.sp-breakdown-row--on').text()).toContain('food')
  })

  it('lists the transactions excluded for a missing rate', async () => {
    const chf = tx('2026-06-12', -80, 'travel')
    chf.data.currency = 'CHF'
    const wrapper = mountView([...TXS, chf])
    const warn = wrapper.find('.sp-warn')
    expect(warn.text()).toContain('1 tx without a EUR rate excluded')
    expect(wrapper.find('.sp-excluded').exists()).toBe(false)
    await warn.trigger('click')
    const row = wrapper.find('.sp-excluded-row')
    expect(row.text()).toContain('2026-06-12')
    expect(row.text()).toContain('80 CHF')
  })

  it('scopes the consolidation to one bank', async () => {
    const wrapper = mountView([
      ...TXS,
      tx('2026-06-20', -70, 'travel', 'Revolut')
    ])
    const bank = wrapper.findAllComponents({ name: 'ComboBox' }).at(0)!
    expect(bank.props('options')).toEqual(['All banks', 'N26', 'Revolut'])
    await bank.vm.$emit('update:modelValue', 'Revolut')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'travel'
    ])
  })

  it('sorts categories alphabetically or by total cost', async () => {
    const wrapper = mountView()
    const catHeader = wrapper.find('thead .sp-sort')
    await catHeader.trigger('click')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'food',
      'rent'
    ])
    await wrapper.findAll('thead .sp-sort').at(-1)!.trigger('click')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'rent',
      'food'
    ])
  })

  it('rounds every amount in the table', () => {
    const wrapper = mountView([
      tx('2026-06-10', -12.34, 'food'),
      tx('2026-06-11', -1.4, 'food')
    ])
    const cells = wrapper.findAll('tbody td').map(c => c.text())
    expect(cells.some(c => c.includes('.'))).toBe(false)
    // 12.34 + 1.40 is rounded, not truncated.
    expect(wrapper.find('tbody .sp-total').text()).toBe('14 EUR')
  })

  it('offers show all when something is hidden', async () => {
    const wrapper = mountView()
    await wrapper.findAll('.sp-chip')[0].trigger('click')
    await wrapper.find('.sp-chip--all').trigger('click')
    expect(wrapper.findAll('tbody .sp-cat-col').map(c => c.text())).toEqual([
      'rent',
      'food'
    ])
  })
})
