import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import TransactionsSection from './TransactionsSection.vue'
import type { Entry } from '../types'

function tx(
  id: string,
  attrs: {
    date: string
    description: string
    amount: number
    account?: string
    category?: string
  }
): Entry {
  return {
    id,
    kind: 'bank_tx',
    source: 'bank_csv',
    external_id: id,
    title: attrs.description,
    occurred_at: `${attrs.date}T12:00:00Z`,
    data: {
      description: attrs.description,
      amount: attrs.amount,
      currency: 'EUR',
      account: attrs.account || 'Checking',
      ...(attrs.category ? { category: attrs.category } : {})
    },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

function makeCtx() {
  const update = vi.fn(
    async (id: string, attrs: Record<string, unknown>) =>
      ({ id, ...attrs }) as unknown as Entry
  )
  const ctx = {
    navigate: vi.fn(),
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    api: {
      entries: {
        list: vi.fn(async () => []),
        update,
        create: vi.fn(),
        delete: vi.fn()
      },
      upload: vi.fn(),
      fetch: vi.fn()
    },
    viewer: { open: vi.fn(), close: vi.fn(), onDelete: vi.fn() }
  }
  return { ctx, update }
}

const TXS = [
  tx('t1', {
    date: '2026-07-02',
    description: 'Grocery store',
    amount: -42.5,
    category: 'food'
  }),
  tx('t2', { date: '2026-07-10', description: 'Salary', amount: 2000 }),
  tx('t3', {
    date: '2026-06-15',
    description: 'Restaurant',
    amount: -30,
    account: 'Joint'
  })
]

function mountSection(txs = TXS) {
  const { ctx, update } = makeCtx()
  const wrapper = mount(TransactionsSection, {
    props: { ctx: ctx as never, txs }
  })
  return { wrapper, update }
}

describe('TransactionsSection', () => {
  it('lists transactions newest first, grouped by month', () => {
    const { wrapper } = mountSection()
    const labels = wrapper.findAll('.ftx-label').map(n => n.text())
    expect(labels).toEqual(['Salary', 'Grocery store', 'Restaurant'])
    const months = wrapper.findAll('.ftx-month').map(n => n.text())
    expect(months).toEqual(['2026-07', '2026-06'])
  })

  it('filters on uncategorized transactions', async () => {
    const { wrapper } = mountSection()
    const catFilter = wrapper.findAllComponents({ name: 'ComboBox' }).at(-1)!
    await catFilter.vm.$emit('update:modelValue', 'Uncategorized')
    await flushPromises()
    const labels = wrapper.findAll('.ftx-label').map(n => n.text())
    expect(labels).toEqual(['Salary', 'Restaurant'])
  })

  it('saves a category typed in the inline editor', async () => {
    const { wrapper, update } = mountSection()
    await wrapper.findAll('.ftx-cat')[0].trigger('click')
    const input = wrapper.find('.ftx-cat-edit input')
    await input.setValue('income')
    await input.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(update).toHaveBeenCalledWith(
      't2',
      expect.objectContaining({
        data: expect.objectContaining({ category: 'income' })
      })
    )
  })

  it('suggests existing categories while editing', async () => {
    const { wrapper } = mountSection()
    await wrapper.findAll('.ftx-cat')[0].trigger('click')
    await wrapper.find('.ftx-cat-edit input').trigger('focus')
    const options = wrapper.findAll('.ftx-cat-edit .ac-option')
    expect(options.map(o => o.text())).toEqual(['food'])
  })
})
