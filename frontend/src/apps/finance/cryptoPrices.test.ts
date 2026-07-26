import { describe, it, expect, vi, afterEach } from 'vitest'
import { fetchCryptoPrices } from './cryptoPrices'

afterEach(() => vi.unstubAllGlobals())

describe('fetchCryptoPrices', () => {
  it('maps known symbols to prices and drops the rest', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      void url
      return {
        ok: true,
        json: async () => ({ bitcoin: { eur: 60000 }, ethereum: { eur: 3000 } })
      }
    })
    vi.stubGlobal('fetch', fetchMock)

    const prices = await fetchCryptoPrices(['btc', 'ETH', 'MYCOIN'], 'EUR')
    expect(prices).toEqual({ BTC: 60000, ETH: 3000 })
    const url = fetchMock.mock.calls[0][0]
    expect(url).toContain('ids=bitcoin,ethereum')
    expect(url).toContain('vs_currencies=eur')
  })

  it('skips the request entirely when no symbol is known', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCryptoPrices(['MYCOIN'], 'EUR')).toEqual({})
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns nothing on an HTTP error', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: false }))
    )
    expect(await fetchCryptoPrices(['BTC'], 'EUR')).toEqual({})
  })
})
