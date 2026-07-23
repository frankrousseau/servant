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

const DOCS: Record<string, Entry[]> = {
  invoice: [
    {
      id: 'inv1',
      kind: 'invoice',
      source: 'invoice_scraper',
      external_id: 'inv1',
      title: 'Free - 19,99 EUR (2026-06)',
      occurred_at: '2026-06-05T12:00:00Z',
      data: { url: 'https://free.fr/invoice.pdf' },
      metadata: {},
      inserted_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z'
    }
  ],
  file: [
    {
      id: 'f1',
      kind: 'file',
      source: 'files_app',
      external_id: null,
      title: 'warranty.pdf',
      occurred_at: null,
      data: { filename: 'warranty.pdf' },
      metadata: {},
      inserted_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z'
    }
  ]
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
        list: vi.fn(
          async (filters?: Record<string, string>) =>
            DOCS[filters?.kind || ''] || []
        ),
        get: vi.fn(async (id: string) => {
          const doc = [...DOCS.invoice, ...DOCS.file].find(d => d.id === id)
          if (!doc) throw new Error('not found')
          return doc
        }),
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
  return { wrapper, update, ctx }
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

  it('links a transaction to an invoice', async () => {
    const { wrapper, update } = mountSection()
    await wrapper.findAll('.ftx-linkbtn')[0].trigger('click')
    await flushPromises()
    const picker = wrapper.getComponent('.ftx-doc-pick')
    expect(picker.props('options')).toEqual([
      { value: 'inv1', label: 'Free - 19,99 EUR (2026-06) - invoice' },
      { value: 'f1', label: 'warranty.pdf - file' }
    ])
    await picker.vm.$emit('update:modelValue', 'inv1')
    await flushPromises()
    expect(update).toHaveBeenCalledWith(
      't2',
      expect.objectContaining({
        data: expect.objectContaining({
          linked_entry_id: 'inv1',
          linked_entry_title: 'Free - 19,99 EUR (2026-06)'
        })
      })
    )
  })

  it('shows the linked document and unlinks it', async () => {
    const linked = TXS.map(t =>
      t.id === 't2'
        ? {
            ...t,
            data: {
              ...t.data,
              linked_entry_id: 'inv1',
              linked_entry_title: 'Free - 19,99 EUR (2026-06)'
            }
          }
        : t
    )
    const { wrapper, update } = mountSection(linked)
    expect(wrapper.find('.ftx-doc-name').text()).toBe(
      'Free - 19,99 EUR (2026-06)'
    )
    await wrapper.find('.ftx-doc-clear').trigger('click')
    await flushPromises()
    expect(update).toHaveBeenCalledWith(
      't2',
      expect.objectContaining({
        data: expect.objectContaining({
          linked_entry_id: null,
          linked_entry_title: null
        })
      })
    )
  })

  it('opens an invoice link through its provider URL', async () => {
    const open = vi.spyOn(window, 'open').mockReturnValue(null)
    const linked = TXS.map(t =>
      t.id === 't2'
        ? {
            ...t,
            data: {
              ...t.data,
              linked_entry_id: 'inv1',
              linked_entry_title: 'Free - 19,99 EUR (2026-06)'
            }
          }
        : t
    )
    const { wrapper } = mountSection(linked)
    await wrapper.find('.ftx-doc-name').trigger('click')
    await flushPromises()
    expect(open).toHaveBeenCalledWith(
      'https://free.fr/invoice.pdf',
      '_blank',
      'noopener'
    )
    open.mockRestore()
  })
})
