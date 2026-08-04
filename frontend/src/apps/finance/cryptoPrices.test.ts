import { describe, it, expect, vi, afterEach } from 'vitest'

import { fetchCryptoPrices } from './cryptoPrices'

afterEach(() => vi.unstubAllGlobals())

function jsonOk(body: unknown) {
  return {
    ok: true,
    json: async () => body
  }
}

describe('fetchCryptoPrices', () => {
  it('maps known symbols via CoinGecko and drops nothing for majors', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      expect(url).toContain('api.coingecko.com')
      return jsonOk({ bitcoin: { eur: 60000 }, ethereum: { eur: 3000 } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const prices = await fetchCryptoPrices(['btc', 'ETH'], 'EUR')
    expect(prices).toEqual({ BTC: 60000, ETH: 3000 })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const url = fetchMock.mock.calls[0][0] as string
    expect(url).toContain('ids=bitcoin,ethereum')
    expect(url).toContain('vs_currencies=eur')
  })

  it('resolves listed tickers via CoinGecko search, best rank first', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
      if (u.includes('coingecko.com/api/v3/search')) {
        return jsonOk({
          coins: [
            { id: 'jupiter', symbol: 'JUP', market_cap_rank: 3814 },
            {
              id: 'jupiter-exchange-solana',
              symbol: 'JUP',
              market_cap_rank: 87
            },
            { id: 'jupiter-perps', symbol: 'JLP', market_cap_rank: 300 }
          ]
        })
      }
      if (u.includes('ids=')) {
        expect(u).toContain('jupiter-exchange-solana')
        return jsonOk({ 'jupiter-exchange-solana': { usd: 0.19 } })
      }
      throw new Error(`unexpected fetch: ${u}`)
    })
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchCryptoPrices(['JUP'], 'USD')).toEqual({ JUP: 0.19 })
    for (const call of fetchMock.mock.calls) {
      expect(String(call[0])).not.toContain('dexscreener')
    }

    // Resolution is cached: a second fetch skips the search request.
    const searches = () =>
      fetchMock.mock.calls.filter(c => String(c[0]).includes('/search')).length
    expect(searches()).toBe(1)
    await fetchCryptoPrices(['JUP'], 'USD')
    expect(searches()).toBe(1)
  })

  it('falls back to DexScreener for tickers CoinGecko does not know', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
      if (u.includes('coingecko.com/api/v3/search'))
        return jsonOk({ coins: [] })
      if (u.includes('dexscreener')) {
        return jsonOk({
          pairs: [
            {
              baseToken: { symbol: 'BONK' },
              priceUsd: '0.00002',
              liquidity: { usd: 1_000_000 }
            },
            {
              baseToken: { symbol: 'BONK' },
              priceUsd: '0.00001',
              liquidity: { usd: 100 }
            }
          ]
        })
      }
      throw new Error(`unexpected fetch: ${url}`)
    })
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchCryptoPrices(['BONK'], 'USD')).toEqual({ BONK: 0.00002 })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('falls back to DexScreener when the search request fails', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
      if (u.includes('coingecko.com/api/v3/search')) return { ok: false }
      if (u.includes('dexscreener')) {
        return jsonOk({
          pairs: [
            {
              baseToken: { symbol: 'FAILSRCH' },
              priceUsd: '3',
              liquidity: { usd: 1000 }
            }
          ]
        })
      }
      throw new Error(`unexpected fetch: ${u}`)
    })
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchCryptoPrices(['FAILSRCH'], 'USD')).toEqual({
      FAILSRCH: 3
    })
  })

  it('converts DexScreener USD quotes to the requested fiat via USDT', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
      if (u.includes('coingecko.com/api/v3/search'))
        return jsonOk({ coins: [] })
      if (u.includes('tether')) return jsonOk({ tether: { eur: 0.92 } })
      if (u.includes('dexscreener')) {
        return jsonOk({
          pairs: [
            {
              baseToken: { symbol: 'WIF' },
              priceUsd: '2.5',
              liquidity: { usd: 500_000 }
            }
          ]
        })
      }
      throw new Error(`unexpected fetch: ${u}`)
    })
    vi.stubGlobal('fetch', fetchMock)

    const prices = await fetchCryptoPrices(['WIF'], 'EUR')
    expect(prices.WIF).toBeCloseTo(2.3, 10)
  })

  it('mixes CoinGecko majors and DexScreener long-tails in one call', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
      if (u.includes('coingecko.com/api/v3/search'))
        return jsonOk({ coins: [] })
      if (u.includes('ids=bitcoin')) return jsonOk({ bitcoin: { usd: 60000 } })
      if (u.includes('dexscreener')) {
        return jsonOk({
          pairs: [
            {
              baseToken: { symbol: 'PEPE' },
              priceUsd: '0.00001',
              liquidity: { usd: 9_000_000 }
            }
          ]
        })
      }
      throw new Error(`unexpected fetch: ${u}`)
    })
    vi.stubGlobal('fetch', fetchMock)

    expect(await fetchCryptoPrices(['BTC', 'PEPE'], 'USD')).toEqual({
      BTC: 60000,
      PEPE: 0.00001
    })
  })

  it('skips network when the symbol list is empty', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCryptoPrices([], 'EUR')).toEqual({})
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns nothing on CoinGecko HTTP error for known symbols', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: false }))
    )
    expect(await fetchCryptoPrices(['BTC'], 'EUR')).toEqual({})
  })

  it('prefers exact baseToken symbol matches on DexScreener', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () =>
        jsonOk({
          pairs: [
            {
              baseToken: { symbol: 'SOL' },
              priceUsd: '999',
              liquidity: { usd: 50_000_000 }
            },
            {
              baseToken: { symbol: 'MYCOIN' },
              priceUsd: '1.5',
              liquidity: { usd: 10_000 }
            }
          ]
        })
      )
    )
    // USD: no USDT conversion fetch.
    expect(await fetchCryptoPrices(['MYCOIN'], 'USD')).toEqual({ MYCOIN: 1.5 })
  })
})
