import { describe, it, expect, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import FinanceApp from './FinanceApp.vue'

import { fakePreferences } from '../fakePreferences'
import type { Entry } from '../types'

vi.mock('./cryptoPrices', () => ({
  fetchCryptoPrices: vi.fn(async () => ({ ETH: 3000 }))
}))

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
  const created = new Map<string, Entry>()
  const create = vi.fn(async (attrs: Record<string, unknown>) => {
    const e = {
      ...entry((attrs.kind as string) || 'entry'),
      ...attrs,
      id: `new${++nextId}`
    } as Entry
    created.set(e.id, e)
    return e
  })
  const update = vi.fn(async (id: string, attrs: Record<string, unknown>) => {
    const e = { ...(created.get(id) || entry('entry')), ...attrs, id } as Entry
    created.set(id, e)
    return e
  })
  return {
    navigate: vi.fn(),
    // Crypto is opt-in; these cases exercise it, so the fixture opts in.
    enabledApps: ['crypto'],
    confirm: { ask: vi.fn().mockResolvedValue(true) },
    preferences: fakePreferences(),
    api: {
      entries: {
        list: vi.fn(
          async (filters?: Record<string, string>) =>
            STORE[filters?.kind || ''] || []
        ),
        get: vi.fn(),
        update,
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
  it('lands on the overview, then shows the Spending tab', async () => {
    const wrapper = mount(FinanceApp, {
      props: { ctx: makeCtx() as never }
    })
    await flushPromises()

    const tabs = wrapper.findAll('.fin-tab')
    expect(tabs.map(t => t.text())).toEqual([
      'Overview',
      'Accounts',
      'Spending',
      'Cryptos',
      'Taxes'
    ])
    // The landing tab answers "where am I", management waits in Accounts.
    expect(wrapper.find('.ov-hero').exists()).toBe(true)

    await tabs[1].trigger('click')
    expect(wrapper.text()).not.toContain('Tradfi')

    await tabs[2].trigger('click')
    expect(wrapper.find('.sp-chart').exists()).toBe(true)
    expect(wrapper.find('.sp-table').exists()).toBe(true)
    expect(wrapper.findAll('.ftx-row').length).toBe(2)
  })

  // Crypto off (the default): the app is tradfi only, and a wallet account
  // plus a portfolio snapshot must leave no trace, including in the totals.
  it('drops everything crypto when the user has not opted in', async () => {
    const ctx = makeCtx()
    ctx.enabledApps = []
    const wallet = entry('account', {
      id: 'w1',
      title: 'Ledger',
      data: { type: 'wallet', currency: 'ETH' }
    })
    const bank = entry('account', {
      id: 'b1',
      title: 'Livret',
      data: { type: 'livret', currency: 'EUR' }
    })
    const snapshot = entry('balance', {
      id: 's1',
      occurred_at: '2026-07-15T12:00:00Z',
      data: { universe: 'crypto', amount: 9999, currency: 'EUR' }
    })
    const bankBalance = entry('balance', {
      id: 's2',
      occurred_at: '2026-07-15T12:00:00Z',
      data: { account_id: 'b1', amount: 500 }
    })
    ctx.api.entries.list = vi.fn(async (filters?: Record<string, string>) => {
      if (filters?.kind === 'account') return [wallet, bank]
      if (filters?.kind === 'balance') return [snapshot, bankBalance]
      if (filters?.kind === 'bank_tx') return []
      return STORE[filters?.kind || ''] || []
    })
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()

    const tabs = wrapper.findAll('.fin-tab')
    expect(tabs.map(t => t.text())).toEqual([
      'Overview',
      'Accounts',
      'Spending',
      'Taxes'
    ])

    // The 9 999 EUR portfolio snapshot must not sneak into the headline.
    expect(wrapper.find('.ov-total').text()).toContain('500')
    expect(wrapper.text()).not.toContain('9 999')
    // One universe left, so the per-universe split line has nothing to say.
    expect(wrapper.find('.ov-splits').exists()).toBe(false)

    await tabs[1].trigger('click')
    const names = wrapper.findAll('.fin-account-name').map(n => n.text())
    expect(names.some(name => name.includes('Livret'))).toBe(true)
    expect(names.some(name => name.includes('Ledger'))).toBe(false)
    expect(wrapper.text()).not.toContain('Crypto')

    await tabs[3].trigger('click')
    expect(wrapper.find('#fin-crypto-tax').exists()).toBe(false)
  })

  it('jumps from an account row to its transactions', async () => {
    const wrapper = mount(FinanceApp, {
      props: { ctx: makeCtx() as never }
    })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[1].trigger('click')

    const chip = wrapper.find('.fin-tx-btn')
    expect(chip.text()).toBe('2')
    await chip.trigger('click')
    await flushPromises()

    // Landed on the Spending tab, transactions list shown.
    expect(wrapper.find('.ftx').exists()).toBe(true)
    expect(wrapper.findAll('.ftx-row').length).toBe(2)
  })

  it('cryptos tab records a token and its quantity', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')

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

  it('corrects the same day quantity instead of stacking records', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')
    await wrapper.find('.fin-crypto-token').setValue('eth')
    await wrapper.find('.fin-crypto-qty').setValue('1.5')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()

    const input = wrapper.find('.fin-crypto-qty-input')
    await input.setValue('2')
    await input.trigger('change')
    await flushPromises()

    // new1 is the account, new2 the day's balance record: updated in place.
    expect(ctx.api.entries.update).toHaveBeenCalledWith(
      'new2',
      expect.objectContaining({
        data: expect.objectContaining({ amount: 2, currency: 'ETH' })
      })
    )
    const balanceCreates = ctx.api.entries.create.mock.calls.filter(
      c => (c[0] as { kind: string }).kind === 'balance'
    )
    expect(balanceCreates.length).toBe(1)
  })

  it('exposes an editable history per token', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')
    await wrapper.find('.fin-crypto-token').setValue('eth')
    await wrapper.find('.fin-crypto-qty').setValue('1.5')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()

    // Scoped: the crypto summary bar has its own caret with the same class.
    await wrapper.find('.fin-accounts .fin-account-caret').trigger('click')
    const row = wrapper.find('.fin-history-row')
    const recordInput = row.find('input')
    expect((recordInput.element as HTMLInputElement).value).toBe('1.5')
    await recordInput.setValue('3')
    await recordInput.trigger('change')
    await flushPromises()

    expect(ctx.api.entries.update).toHaveBeenCalledWith(
      'new2',
      expect.objectContaining({
        title: 'ETH: 3',
        data: expect.objectContaining({ amount: 3 })
      })
    )
  })

  it('shows the spot price and value estimate for identifiable tokens', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')
    await wrapper.find('.fin-crypto-token').setValue('eth')
    await wrapper.find('.fin-crypto-qty').setValue('1.5')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()

    // The thousands separator depends on the host locale.
    expect(wrapper.find('.fin-crypto-price').text()).toMatch(/^3.000 EUR$/)
    // No manual rate: the spot estimate steps in, marked approximate.
    expect(wrapper.find('.fin-account-converted').text()).toMatch(
      /^≈ 4.500 EUR$/
    )
  })

  it('shows the spot total and records portfolio snapshots without stacking', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')
    await wrapper.find('.fin-crypto-token').setValue('eth')
    await wrapper.find('.fin-crypto-qty').setValue('1.5')
    await wrapper.find('.fin-crypto-add').trigger('submit')
    await flushPromises()

    // 1.5 ETH at spot 3000, no manual rate: approximate total.
    expect(wrapper.find('.fin-crypto-summary .fin-total').text()).toMatch(
      /^≈ 4.500 EUR$/
    )

    await wrapper.find('.fin-crypto-snapshot').trigger('click')
    await flushPromises()
    expect(ctx.api.entries.create).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'balance',
        title: 'Crypto portfolio: 4500 EUR',
        data: { universe: 'crypto', amount: 4500, currency: 'EUR' }
      })
    )

    // Same day again: correct the day's snapshot instead of stacking.
    await wrapper.find('.fin-crypto-snapshot').trigger('click')
    await flushPromises()
    expect(ctx.api.entries.update).toHaveBeenCalledWith(
      'new3',
      expect.objectContaining({
        data: expect.objectContaining({ universe: 'crypto', amount: 4500 })
      })
    )
    const portfolioCreates = ctx.api.entries.create.mock.calls.filter(
      call =>
        (call[0] as { data?: { universe?: string } }).data?.universe ===
        'crypto'
    )
    expect(portfolioCreates.length).toBe(1)

    // History behind the caret, deletable like any snapshot.
    await wrapper
      .find('.fin-crypto-summary .fin-account-caret')
      .trigger('click')
    expect(wrapper.find('.fin-history-amount').text()).toMatch(/^4.500 EUR$/)
  })

  it('drives the accounts-tab crypto section from portfolio snapshots', async () => {
    const ctx = makeCtx()
    const wallet = entry('account', {
      id: 'w1',
      title: 'BTC',
      data: { type: 'wallet', currency: 'BTC' }
    })
    const quantity = entry('balance', {
      id: 'q1',
      occurred_at: '2026-07-01T12:00:00Z',
      data: { account_id: 'w1', amount: 2, currency: 'BTC' }
    })
    const snapshot = entry('balance', {
      id: 's1',
      occurred_at: '2026-07-15T12:00:00Z',
      data: { universe: 'crypto', amount: 9999, currency: 'EUR' }
    })
    ctx.api.entries.list = vi.fn(async (filters?: Record<string, string>) => {
      if (filters?.kind === 'account') return [wallet]
      if (filters?.kind === 'balance') return [quantity, snapshot]
      return STORE[filters?.kind || ''] || []
    })
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[1].trigger('click')

    const sections = wrapper.findAll('.fin-universe')
    const cryptoSection = sections[sections.length - 1]
    expect(cryptoSection.find('.fin-total').text()).toMatch(/^9.999 EUR$/)
  })

  it('keeps an orphaned portfolio snapshot reachable after its last token is deleted', async () => {
    const ctx = makeCtx()
    const snapshot = entry('balance', {
      id: 's1',
      occurred_at: '2026-07-15T12:00:00Z',
      data: { universe: 'crypto', amount: 9999, currency: 'EUR' }
    })
    ctx.api.entries.list = vi.fn(async (filters?: Record<string, string>) => {
      if (filters?.kind === 'account') return []
      if (filters?.kind === 'balance') return [snapshot]
      return STORE[filters?.kind || ''] || []
    })
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[3].trigger('click')

    // No wallet accounts left, but the snapshot still counts toward other
    // totals: the summary bar must stay reachable, not hidden behind
    // "No tokens yet".
    expect(wrapper.find('.fin-crypto-summary').exists()).toBe(true)

    await wrapper
      .find('.fin-crypto-summary .fin-account-caret')
      .trigger('click')
    const row = wrapper.find('.fin-history-row')
    expect(row.exists()).toBe(true)
    expect(row.find('.fin-history-amount').text()).toMatch(/^9.999 EUR$/)
  })

  it('saves a tax rate from the taxes tab on change', async () => {
    const ctx = makeCtx()
    const wrapper = mount(FinanceApp, { props: { ctx: ctx as never } })
    await flushPromises()
    await wrapper.findAll('.fin-tab')[4].trigger('click')

    const input = wrapper.find('#fin-crypto-tax')
    expect(input.exists()).toBe(true)
    await input.setValue('31,4')
    await input.trigger('change')
    await flushPromises()

    const call = (ctx.api.entries.create as ReturnType<typeof vi.fn>).mock
      .calls[0][0]
    expect(call.data.crypto_tax_pct).toBe(31.4)
  })
})
