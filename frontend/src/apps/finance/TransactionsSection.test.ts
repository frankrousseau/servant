import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import TransactionsSection from './TransactionsSection.vue'
import ComboBox from '../../components/ComboBox.vue'

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

  it('filters on flow direction', async () => {
    const { wrapper } = mountSection()
    const flow = wrapper.findAllComponents({ name: 'ComboBox' }).at(0)!
    await flow.vm.$emit('update:modelValue', 'Outgoing')
    await flushPromises()
    expect(wrapper.findAll('.ftx-label').map(n => n.text())).toEqual([
      'Grocery store',
      'Restaurant'
    ])
    await flow.vm.$emit('update:modelValue', 'Incoming')
    await flushPromises()
    expect(wrapper.findAll('.ftx-label').map(n => n.text())).toEqual(['Salary'])
  })

  it('presets the account filter from focusAccount, case-insensitive', () => {
    const { ctx } = makeCtx()
    const wrapper = mount(TransactionsSection, {
      props: { ctx: ctx as never, txs: TXS, focusAccount: 'joint' }
    })
    expect(wrapper.findAll('.ftx-label').map(n => n.text())).toEqual([
      'Restaurant'
    ])
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
    const picker = wrapper
      .findAllComponents(ComboBox)
      .find(c => c.classes().includes('ftx-doc-pick'))!
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

  it('finds duplicates, keeps the balance-bearing one, deletes the rest', async () => {
    const dupA = tx('d1', {
      date: '2026-07-05',
      description: 'EDF  Facture',
      amount: -55
    })
    dupA.data.balance = 900
    const dupB = {
      ...tx('d2', {
        date: '2026-07-05',
        description: 'edf facture',
        amount: -55,
        account: 'Joint'
      }),
      inserted_at: '2025-12-01T00:00:00Z'
    }
    const { wrapper, ctx } = mountSection([...TXS, dupA, dupB])
    await wrapper
      .findAll('.ftx-dedup-btn')
      .find(b => b.text() === 'Duplicates')!
      .trigger('click')

    const rows = wrapper.findAll('.ftx-dedup-row')
    expect(rows.length).toBe(2)
    // dupA carries the balance: kept despite being the newer import.
    const checked = rows.map(
      r => (r.find('input').element as HTMLInputElement).checked
    )
    expect(checked.filter(Boolean).length).toBe(1)

    await wrapper.find('.ftx-dedup-delete').trigger('click')
    await flushPromises()
    expect(ctx.api.entries.delete).toHaveBeenCalledTimes(1)
    expect(ctx.api.entries.delete).toHaveBeenCalledWith('d2')
    expect(wrapper.emitted('deleted')).toEqual([['d2']])
  })

  it('groups near-date duplicates and preselects only likely twins', async () => {
    // CSV and bank-API imports of the same movement: label worded
    // differently by each source, booking date shifted by a day.
    const csvTx = tx('n1', {
      date: '2026-07-05',
      description: 'VIR SEPA ACME CORP',
      amount: -120
    })
    const apiTx = {
      ...tx('n2', {
        date: '2026-07-06',
        description: 'Acme salary',
        amount: -120
      }),
      source: 'enable_banking',
      inserted_at: '2026-02-01T00:00:00Z'
    }
    // Same source, same amount, unrelated label: shown but not preselected.
    const other = {
      ...tx('n3', { date: '2026-07-06', description: 'Fnac', amount: -120 }),
      inserted_at: '2026-03-01T00:00:00Z'
    }
    const { wrapper } = mountSection([...TXS, csvTx, apiTx, other])
    await wrapper
      .findAll('.ftx-dedup-btn')
      .find(b => b.text() === 'Duplicates')!
      .trigger('click')

    const rows = wrapper.findAll('.ftx-dedup-row')
    const state = rows.map(r => [
      r.find('.ftx-label').text(),
      (r.find('input').element as HTMLInputElement).checked
    ])
    expect(state).toEqual([
      ['VIR SEPA ACME CORP', false],
      ['Acme salary', true],
      ['Fnac', false]
    ])
  })

  it('reports when there is nothing to deduplicate', async () => {
    const { wrapper } = mountSection()
    await wrapper
      .findAll('.ftx-dedup-btn')
      .find(b => b.text() === 'Duplicates')!
      .trigger('click')
    expect(wrapper.find('.ftx-dedup').text()).toContain('No duplicates found.')
  })

  it('applies a category to the multi-selection', async () => {
    const { wrapper, update } = mountSection()
    const checks = wrapper.findAll('.ftx-check')
    await checks[0].setValue(true)
    await checks[1].setValue(true)
    const bulk = wrapper.find('.ftx-bulk-cat input')
    await bulk.setValue('perso')
    await bulk.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(update).toHaveBeenCalledTimes(2)
    expect(update).toHaveBeenCalledWith(
      't2',
      expect.objectContaining({
        data: expect.objectContaining({ category: 'perso' })
      })
    )
    expect(wrapper.find('.ftx-bulk').exists()).toBe(false)
  })

  it('suggests categories from similar labels and applies them', async () => {
    const txs = [
      tx('c1', {
        date: '2026-07-01',
        description: 'CB CARREFOUR 12/07',
        amount: -20,
        category: 'food'
      }),
      tx('c2', {
        date: '2026-07-08',
        description: 'CB CARREFOUR 15/07',
        amount: -30
      }),
      tx('c3', { date: '2026-07-09', description: 'Mystery shop', amount: -5 })
    ]
    const { wrapper, update } = mountSection(txs)
    await wrapper
      .findAll('.ftx-dedup-btn')
      .find(b => b.text() === 'Auto-categorize')!
      .trigger('click')
    const rows = wrapper.findAll('.ftx-auto-row')
    expect(rows.length).toBe(1)
    expect(rows[0].text()).toContain('food')
    expect(rows[0].text()).toContain('1 tx')

    await wrapper.find('.ftx-auto-apply').trigger('click')
    await flushPromises()
    expect(update).toHaveBeenCalledTimes(1)
    expect(update).toHaveBeenCalledWith(
      'c2',
      expect.objectContaining({
        data: expect.objectContaining({ category: 'food' })
      })
    )
  })

  it('deletes a transaction after confirmation', async () => {
    const { wrapper, ctx } = mountSection()
    await wrapper.findAll('.ftx-del')[0].trigger('click')
    await flushPromises()
    expect(ctx.api.entries.delete).toHaveBeenCalledWith('t2')
    expect(wrapper.emitted('deleted')).toEqual([['t2']])
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
