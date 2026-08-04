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

  it('falls back to DexScreener for unknown tickers (USD vs)', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (String(url).includes('dexscreener')) {
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
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('converts DexScreener USD quotes to the requested fiat via USDT', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      const u = String(url)
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
