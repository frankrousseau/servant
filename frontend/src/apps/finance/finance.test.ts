import { describe, it, expect } from 'vitest'
import {
  buildAccounts,
  freshnessDays,
  freshnessLevel,
  rateFor,
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
})

describe('universeCurve', () => {
  const eur: Account = {
    key: 'a',
    entryId: 'a',
    name: 'Bank',
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
