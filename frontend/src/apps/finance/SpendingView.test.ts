import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import SpendingView from './SpendingView.vue'
import type { Entry } from '../types'

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

function mountView(txs = TXS) {
  return mount(SpendingView, {
    props: { txs, accounts: [], rates: {}, refCurrency: 'EUR' }
  })
}

describe('SpendingView', () => {
  beforeEach(() => localStorage.clear())

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
    expect(
      JSON.parse(localStorage.getItem('servant_finance_hidden_categories')!)
    ).toEqual(['rent'])
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

  it('shows a pie for the chosen period', async () => {
    const wrapper = mountView()
    const chartType = wrapper.findAllComponents({ name: 'ComboBox' }).at(0)!
    await chartType.vm.$emit('update:modelValue', 'Pie')
    // Defaults to the most recent month: only food spent in 2026-07.
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
