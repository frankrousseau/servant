import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import OverviewView from './OverviewView.vue'
import { buildAccounts, snapshotSeries } from './finance'
import type { Entry } from '../types'

function entry(
  kind: string,
  attrs: Partial<Entry> & { data?: Record<string, unknown> } = {}
): Entry {
  return {
    id: attrs.id || Math.random().toString(36).slice(2),
    kind,
    source: 'test',
    external_id: null,
    title: attrs.title ?? null,
    occurred_at: attrs.occurred_at ?? null,
    data: attrs.data || {},
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

const accountEntry = (id: string, name: string, currency = 'EUR') =>
  entry('account', { id, title: name, data: { type: 'bank', currency } })

const balanceEntry = (accountId: string, date: string, amount: number) =>
  entry('balance', {
    occurred_at: `${date}T12:00:00Z`,
    data: { account_id: accountId, amount, currency: 'EUR' }
  })

const spendTx = (
  date: string,
  amount: number,
  category?: string,
  currency = 'EUR'
) =>
  entry('bank_tx', {
    occurred_at: `${date}T12:00:00Z`,
    data: {
      account: 'Bank',
      amount,
      currency,
      ...(category ? { category } : {})
    }
  })

function mountOverview(
  entities: Entry[],
  balances: Entry[],
  txs: Entry[],
  rates: Record<string, number> = {}
) {
  const accounts = buildAccounts(entities, txs)
  const seriesByKey = new Map(
    accounts.map(a => [a.key, snapshotSeries(a, balances, txs)])
  )
  return mount(OverviewView, {
    props: {
      accounts,
      seriesByKey,
      txs,
      rates,
      refCurrency: 'EUR',
      today: '2026-07-15'
    }
  })
}

describe('OverviewView', () => {
  it('shows the combined total, 30d delta and month digest', () => {
    const wrapper = mountOverview(
      [accountEntry('a1', 'Bank')],
      [balanceEntry('a1', '2026-07-10', 900)],
      [spendTx('2026-07-03', -60, 'rent'), spendTx('2026-07-05', -40, 'food')]
    )

    expect(wrapper.find('.ov-total').text()).toBe('900 EUR')
    expect(wrapper.find('.ov-delta').text()).toBe('+900 EUR / 30d')
    expect(wrapper.find('.ov-spent-amount').text()).toBe('100 EUR')
    const cats = wrapper.findAll('.ov-cat').map(c => c.text())
    expect(cats[0]).toContain('rent')
    expect(cats[1]).toContain('food')
    // Fresh balance, every currency rated: nothing to do.
    expect(wrapper.findAll('.ov-alert')).toHaveLength(0)
    expect(wrapper.text()).toContain('Everything fresh')
  })

  it('lists actionable alerts and navigates on click', async () => {
    const wrapper = mountOverview(
      [accountEntry('a1', 'Old'), accountEntry('a2', 'Broker', 'USD')],
      [
        balanceEntry('a1', '2026-01-01', 500),
        balanceEntry('a2', '2026-07-14', 100)
      ],
      [spendTx('2026-07-05', -80, 'travel', 'CHF')]
    )

    const alerts = wrapper.findAll('.ov-alert').map(a => a.text())
    expect(alerts).toHaveLength(3)
    expect(alerts[0]).toContain('no balance newer than 35 days')
    expect(alerts[0]).toContain('Old')
    expect(alerts[1]).toContain('No EUR rate for: Broker')
    expect(alerts[2]).toContain('1 transaction(s) not counted in spending')

    await wrapper.findAll('.ov-alert')[0].trigger('click')
    expect(wrapper.emitted('go')![0]).toEqual(['accounts'])
    await wrapper.findAll('.ov-alert')[2].trigger('click')
    expect(wrapper.emitted('go')![1]).toEqual(['spending'])
  })

  it('invites to the accounts tab when empty', async () => {
    const wrapper = mountOverview([], [], [])
    expect(wrapper.find('.ov-empty').exists()).toBe(true)
    await wrapper.find('.ov-link').trigger('click')
    expect(wrapper.emitted('go')![0]).toEqual(['accounts'])
  })
})
