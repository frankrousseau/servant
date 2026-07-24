import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import SpendingView from './SpendingView.vue'
import type { Entry } from '../types'

function tx(date: string, amount: number, category?: string): Entry {
  return {
    id: Math.random().toString(36).slice(2),
    kind: 'bank_tx',
    source: 'test',
    external_id: null,
    title: null,
    occurred_at: `${date}T12:00:00Z`,
    data: {
      account: 'N26',
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
