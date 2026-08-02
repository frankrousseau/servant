import { describe, it, expect } from 'vitest'

import {
  buildAccounts,
  freshnessDays,
  freshnessLevel,
  monthlySpending,
  rateFor,
  sharedTxNames,
  snapshotSeries,
  universeCurve,
  valueAt
} from './finance'
import type { Account } from './finance'
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

const accountEntry = (
  id: string,
  name: string,
  type: string,
  currency: string
) => entry('account', { id, title: name, data: { type, currency } })

const bankTx = (account: string, occurredAt: string, balance: number | null) =>
  entry('bank_tx', {
    occurred_at: occurredAt,
    data: { account, balance, currency: 'EUR', amount: -10 }
  })

const spendTx = (
  account: string,
  occurredAt: string,
  amount: number,
  category?: string
) =>
  entry('bank_tx', {
    occurred_at: occurredAt,
    data: {
      account,
      amount,
      currency: 'EUR',
      ...(category ? { category } : {})
    }
  })

const balanceEntry = (accountId: string, occurredAt: string, amount: number) =>
  entry('balance', {
    occurred_at: occurredAt,
    data: { account_id: accountId, amount, currency: 'EUR' }
  })

describe('buildAccounts', () => {
  it('mixes entity accounts and accounts derived from bank_tx', () => {
    const accounts = buildAccounts(
      [accountEntry('a1', 'Livret A', 'livret', 'EUR')],
      [bankTx('N26 Frank', '2026-06-01T12:00:00Z', 1200)]
    )
    expect(accounts.map(a => [a.name, a.derived, a.universe])).toEqual([
      ['Livret A', false, 'tradfi'],
      ['N26 Frank', true, 'tradfi']
    ])
  })

  it('lets an entity account claim its CSV name', () => {
    const accounts = buildAccounts(
      [accountEntry('a1', 'N26 Frank', 'bank', 'EUR')],
      [bankTx('n26 frank', '2026-06-01T12:00:00Z', 1200)]
    )
    expect(accounts).toHaveLength(1)
    expect(accounts[0].derived).toBe(false)
  })

  it('wallets belong to the crypto universe', () => {
    const [a] = buildAccounts(
      [accountEntry('w1', 'Ledger ETH', 'wallet', 'ETH')],
      []
    )
    expect(a.universe).toBe('crypto')
  })

  it('ignores bank_tx without balance data', () => {
    expect(
      buildAccounts([], [bankTx('X', '2026-06-01T12:00:00Z', null)])
    ).toEqual([])
  })
})

describe('snapshotSeries', () => {
  it('keeps the last observation per day, sorted ascending', () => {
    const [account] = buildAccounts(
      [],
      [bankTx('N26', '2026-06-01T08:00:00Z', 100)]
    )
    const series = snapshotSeries(
      account,
      [],
      [
        bankTx('N26', '2026-06-02T08:00:00Z', 90),
        bankTx('N26', '2026-06-01T08:00:00Z', 100),
        bankTx('N26', '2026-06-01T15:00:00Z', 80)
      ]
    )
    expect(series).toEqual([
      { date: '2026-06-01', amount: 80 },
      { date: '2026-06-02', amount: 90 }
    ])
  })

  it('merges manual snapshots with tx balances for a claiming entity', () => {
    const [account] = buildAccounts(
      [accountEntry('a1', 'N26', 'bank', 'EUR')],
      []
    )
    const series = snapshotSeries(
      account,
      [balanceEntry('a1', '2026-06-10T12:00:00Z', 1500)],
      [bankTx('N26', '2026-06-01T12:00:00Z', 1000)]
    )
    expect(series).toEqual([
      { date: '2026-06-01', amount: 1000 },
      { date: '2026-06-10', amount: 1500 }
    ])
  })

  it('ignores balance entries of other accounts', () => {
    const [account] = buildAccounts(
      [accountEntry('a1', 'Cash', 'cash', 'EUR')],
      []
    )
    const series = snapshotSeries(
      account,
      [balanceEntry('other', '2026-06-10T12:00:00Z', 999)],
      []
    )
    expect(series).toEqual([])
  })

  it('projects past the last snapshot using balance-less transactions', () => {
    const [account] = buildAccounts(
      [accountEntry('a1', 'N26', 'bank', 'EUR')],
      []
    )
    const txs = [
      // Before the snapshot: already reflected in it, ignored.
      spendTx('N26', '2026-06-05T10:00:00Z', -50),
      spendTx('N26', '2026-06-12T10:00:00Z', -30),
      spendTx('N26', '2026-06-12T18:00:00Z', -20),
      spendTx('N26', '2026-06-15T10:00:00Z', 100)
    ]
    const series = snapshotSeries(
      account,
      [balanceEntry('a1', '2026-06-10T12:00:00Z', 1000)],
      txs
    )
    expect(series).toEqual([
      { date: '2026-06-10', amount: 1000 },
      { date: '2026-06-12', amount: 950 },
      { date: '2026-06-15', amount: 1050 }
    ])
  })

  it('does not project when transactions carry their own balance', () => {
    const [account] = buildAccounts(
      [],
      [bankTx('N26', '2026-06-01T08:00:00Z', 100)]
    )
    const series = snapshotSeries(
      account,
      [],
      [bankTx('N26', '2026-06-01T08:00:00Z', 100)]
    )
    expect(series).toEqual([{ date: '2026-06-01', amount: 100 }])
  })

  it('matches transactions through the account identifier', () => {
    const entity = entry('account', {
      id: 'a1',
      title: 'My checking',
      data: { type: 'bank', currency: 'EUR', identifier: 'COMPTE 0001' }
    })
    const txs = [
      bankTx('compte 0001', '2026-06-01T12:00:00Z', 500),
      spendTx('COMPTE 0001', '2026-06-02T12:00:00Z', -100)
    ]
    const accounts = buildAccounts([entity], txs)
    // The identifier claims the CSV account: no derived duplicate.
    expect(accounts).toHaveLength(1)
    const series = snapshotSeries(accounts[0], [], txs)
    expect(series).toEqual([
      { date: '2026-06-01', amount: 500 },
      { date: '2026-06-02', amount: 400 }
    ])
  })
})

describe('monthlySpending', () => {
  it('consolidates outgoing amounts by month and category', () => {
    const { months, rows, excluded } = monthlySpending(
      [
        spendTx('N26', '2026-05-10T12:00:00Z', -40, 'food'),
        spendTx('N26', '2026-06-05T12:00:00Z', -60, 'food'),
        spendTx('N26', '2026-06-20T12:00:00Z', -10),
        // Income never counts as spending.
        spendTx('N26', '2026-06-25T12:00:00Z', 2000, 'salary')
      ],
      {},
      'EUR'
    )
    expect(excluded).toEqual([])
    expect(months).toEqual(['2026-05', '2026-06'])
    expect(rows).toEqual([
      {
        category: 'food',
        byMonth: { '2026-05': 40, '2026-06': 60 },
        total: 100
      },
      { category: 'uncategorized', byMonth: { '2026-06': 10 }, total: 10 }
    ])
  })

  it('counts transactions of a shared account half', () => {
    const entity = entry('account', {
      id: 'a1',
      title: 'Joint',
      data: { type: 'bank', currency: 'EUR', shared: true }
    })
    const accounts = buildAccounts([entity], [])
    expect(accounts[0].shared).toBe(true)
    const { rows } = monthlySpending(
      [
        spendTx('Joint', '2026-06-10T12:00:00Z', -80, 'food'),
        spendTx('Solo', '2026-06-11T12:00:00Z', -10, 'food')
      ],
      {},
      'EUR',
      sharedTxNames(accounts)
    )
    expect(rows).toEqual([
      { category: 'food', byMonth: { '2026-06': 50 }, total: 50 }
    ])
  })

  it('converts currencies and excludes those without a rate', () => {
    const usd = entry('bank_tx', {
      occurred_at: '2026-06-01T12:00:00Z',
      data: { account: 'Broker', amount: -100, currency: 'USD' }
    })
    const chf = entry('bank_tx', {
      occurred_at: '2026-06-01T12:00:00Z',
      data: { account: 'Swiss', amount: -100, currency: 'CHF' }
    })
    const { rows, excluded } = monthlySpending([usd, chf], { USD: 0.9 }, 'EUR')
    expect(excluded).toEqual([chf])
    expect(rows).toEqual([
      { category: 'uncategorized', byMonth: { '2026-06': 90 }, total: 90 }
    ])
  })
})

describe('universeCurve', () => {
  const eur: Account = {
    key: 'a',
    entryId: 'a',
    name: 'Bank',
    identifier: null,
    shared: false,
    type: 'bank',
    currency: 'EUR',
    universe: 'tradfi',
    derived: false
  }
  const usd: Account = { ...eur, key: 'b', name: 'Broker', currency: 'USD' }

  it('forward-fills and sums accounts in the reference currency', () => {
    const { points, excluded } = universeCurve(
      [eur, usd],
      new Map([
        [
          'a',
          [
            { date: '2026-01-01', amount: 100 },
            { date: '2026-03-01', amount: 200 }
          ]
        ],
        ['b', [{ date: '2026-02-01', amount: 50 }]]
      ]),
      { USD: 0.9 },
      'EUR'
    )
    expect(excluded).toEqual([])
    expect(points).toEqual([
      { date: '2026-01-01', amount: 100 },
      { date: '2026-02-01', amount: 145 },
      { date: '2026-03-01', amount: 245 }
    ])
  })

  it('excludes accounts without a rate instead of counting them at zero', () => {
    const { points, excluded } = universeCurve(
      [eur, usd],
      new Map([
        ['a', [{ date: '2026-01-01', amount: 100 }]],
        ['b', [{ date: '2026-01-01', amount: 50 }]]
      ]),
      {},
      'EUR'
    )
    expect(excluded).toEqual(['Broker'])
    expect(points).toEqual([{ date: '2026-01-01', amount: 100 }])
  })
})

describe('rates and freshness', () => {
  it('rateFor returns 1 for the reference and null when missing', () => {
    expect(rateFor('EUR', 'EUR', {})).toBe(1)
    expect(rateFor('USD', 'EUR', { USD: 0.9 })).toBe(0.9)
    expect(rateFor('USD', 'EUR', {})).toBeNull()
    expect(rateFor('USD', 'EUR', { USD: 0 })).toBeNull()
  })

  it('valueAt reads the forward-filled curve', () => {
    const points = [
      { date: '2026-01-01', amount: 100 },
      { date: '2026-02-01', amount: 200 }
    ]
    expect(valueAt(points, '2025-12-31')).toBe(0)
    expect(valueAt(points, '2026-01-15')).toBe(100)
    expect(valueAt(points, '2026-02-01')).toBe(200)
  })

  it('freshness measures days since the last snapshot', () => {
    const series = [{ date: '2026-06-01', amount: 1 }]
    expect(freshnessDays(series, '2026-07-06')).toBe(35)
    expect(freshnessDays([], '2026-07-06')).toBeNull()
    expect(freshnessLevel(35)).toBe('ok')
    expect(freshnessLevel(36)).toBe('warn')
    expect(freshnessLevel(91)).toBe('stale')
    expect(freshnessLevel(null)).toBe('stale')
  })
})
