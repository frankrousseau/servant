import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import FinanceApp from './FinanceApp.vue'
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

const STORE: Record<string, Entry[]> = {
  account: [],
  balance: [],
  prefs: [],
  bank_tx: [
    entry('bank_tx', {
      id: 't1',
      occurred_at: '2026-07-02T12:00:00Z',
      data: {
        account: 'N26',
        description: 'Grocery store',
        amount: -42.5,
        currency: 'EUR',
        balance: 1000,
        category: 'food'
      }
    }),
    entry('bank_tx', {
      id: 't2',
      occurred_at: '2026-06-10T12:00:00Z',
      data: {
        account: 'N26',
        description: 'Restaurant',
        amount: -30,
        currency: 'EUR',
        balance: 1042.5
      }
    })
  ]
}

function makeCtx() {
  let nextId = 0
  const create = vi.fn(
    async (attrs: Record<string, unknown>) =>
      ({
        ...entry((attrs.kind as string) || 'entry'),
        ...attrs,
        id: `new${++nextId}`
      }) as Entry
  )
  return {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(
          async (filters?: Record<string, string>) =>
            STORE[filters?.kind || ''] || []
        ),
        get: vi.fn(),
        update: vi.fn(),
        create,
        delete: vi.fn()
      },
      upload: vi.fn(),
      fetch: vi.fn()
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
}

describe('FinanceApp tabs', () => {
  it('shows the Spending tab with chart and table', async () => {
    const wrapper = mount(FinanceApp, {
      props: { ctx: makeCtx() as never }
    })
    await flushPromises()

    const tabs = wrapper.findAll('.fin-tab')
    expect(tabs.map(t => t.text())).toEqual(['Accounts', 'Spending', 'Cryptos'])
    // The default universe goes untitled.
    expect(wrapper.text()).not.toContain('Tradfi')

    await tabs[1].trigger('click')
    expect(wrapper.find('.sp-chart').exists()).toBe(true)
    expect(wrapper.find('.sp-table').exists()).toBe(true)
    expect(wrapper.findAll('.ftx-row').length).toBe(2)
  })

  it('cryptos tab records a token and its quantity', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[2].trigger('click')

    await wrapper.find('.fin-crypto-token').setValue('eth')
    await wrapper.find('.fin-crypto-qty').setValue('1,5')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()

    expect(ctx.api.entries.create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'account',
        title: 'ETH',
        data: { type: 'wallet', currency: 'ETH' }
      })
    )
    expect(ctx.api.entries.create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'balance',
        data: expect.objectContaining({ amount: 1.5, currency: 'ETH' })
      })
    )
    const qty = wrapper.find('.fin-crypto-qty-input')
      .element as HTMLInputElement
    expect(qty.value).toBe('1.5')

    // Same token again: records a quantity, no duplicate account.
    await wrapper.find('.fin-crypto-token').setValue('ETH')
    await wrapper.find('.fin-crypto-qty').setValue('2')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()
    const accountCreates = ctx.api.entries.create.mock.calls.filter(
      c => (c[0] as { kind: string }).kind === 'account'
    )
    expect(accountCreates.length).toBe(1)
  })
})
