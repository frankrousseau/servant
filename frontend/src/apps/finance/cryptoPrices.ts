// Spot prices for the Cryptos tab, fetched from the browser (display only:
// the curve and totals still go through manual rates). Majors use CoinGecko
// (stable fiat pairs). Everything else falls back to DexScreener search by
// ticker (highest-liquidity pair); those quotes are in USD and converted to
// `vs` via USDT on CoinGecko.

const COINGECKO_IDS: Record<string, string> = {
  AAVE: 'aave',
  ADA: 'cardano',
  ALGO: 'algorand',
  ARB: 'arbitrum',
  ATOM: 'cosmos',
  AVAX: 'avalanche-2',
  BCH: 'bitcoin-cash',
  BNB: 'binancecoin',
  BTC: 'bitcoin',
  DOGE: 'dogecoin',
  DOT: 'polkadot',
  ETC: 'ethereum-classic',
  ETH: 'ethereum',
  FIL: 'filecoin',
  LINK: 'chainlink',
  LTC: 'litecoin',
  NEAR: 'near',
  OP: 'optimism',
  POL: 'polygon-ecosystem-token',
  SOL: 'solana',
  UNI: 'uniswap',
  XLM: 'stellar',
  XMR: 'monero',
  XRP: 'ripple',
  XTZ: 'tezos'
}

type DexPair = {
  baseToken?: { symbol?: string }
  quoteToken?: { symbol?: string }
  priceUsd?: string | number
  liquidity?: { usd?: number }
}

// Symbol -> price in `vs`. Known CoinGecko ids first; DexScreener for the rest.
export async function fetchCryptoPrices(
  symbols: string[],
  vs: string
): Promise<Record<string, number>> {
  const unique = [...new Set(symbols.map(s => s.toUpperCase()).filter(Boolean))]
  if (!unique.length) return {}

  const known = unique.filter(s => s in COINGECKO_IDS)
  const unknown = unique.filter(s => !(s in COINGECKO_IDS))

  const [gecko, dex] = await Promise.all([
    fetchCoinGecko(known, vs),
    fetchDexScreener(unknown, vs)
  ])
  return { ...gecko, ...dex }
}

async function fetchCoinGecko(
  symbols: string[],
  vs: string
): Promise<Record<string, number>> {
  if (!symbols.length) return {}
  const ids = symbols.map(s => COINGECKO_IDS[s]).join(',')
  const currency = vs.toLowerCase()
  const res = await fetch(
    `https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=${currency}`
  )
  if (!res.ok) return {}
  const body = (await res.json()) as Record<string, Record<string, number>>
  const out: Record<string, number> = {}
  for (const s of symbols) {
    const price = body[COINGECKO_IDS[s]]?.[currency]
    if (typeof price === 'number') out[s] = price
  }
  return out
}

async function fetchDexScreener(
  symbols: string[],
  vs: string
): Promise<Record<string, number>> {
  if (!symbols.length) return {}
  const usdToVs = await usdToVsRate(vs)
  if (usdToVs == null) return {}

  const entries = await Promise.all(
    symbols.map(async s => {
      const usd = await dexPriceUsd(s)
      if (usd == null) return null
      return [s, usd * usdToVs] as const
    })
  )

  const out: Record<string, number> = {}
  for (const entry of entries) {
    if (entry) out[entry[0]] = entry[1]
  }
  return out
}

// USDT ≈ USD: CoinGecko gives us the fiat amount of one dollar when vs ≠ USD.
async function usdToVsRate(vs: string): Promise<number | null> {
  const currency = vs.toLowerCase()
  if (currency === 'usd') return 1
  const res = await fetch(
    `https://api.coingecko.com/api/v3/simple/price?ids=tether&vs_currencies=${currency}`
  )
  if (!res.ok) return null
  const body = (await res.json()) as Record<string, Record<string, number>>
  const rate = body.tether?.[currency]
  return typeof rate === 'number' ? rate : null
}

async function dexPriceUsd(symbol: string): Promise<number | null> {
  const res = await fetch(
    `https://api.dexscreener.com/latest/dex/search?q=${encodeURIComponent(symbol)}`
  )
  if (!res.ok) return null
  const body = (await res.json()) as { pairs?: DexPair[] | null }
  const pairs = body.pairs || []
  const matched = pairs.filter(
    p => p.baseToken?.symbol?.toUpperCase() === symbol
  )
  const pool = bestPair(matched.length ? matched : pairs)
  if (!pool?.priceUsd) return null
  const n = Number(pool.priceUsd)
  return Number.isFinite(n) ? n : null
}

function bestPair(pairs: DexPair[]): DexPair | null {
  if (!pairs.length) return null
  let best = pairs[0]
  let bestLiq = best.liquidity?.usd ?? 0
  for (let i = 1; i < pairs.length; i++) {
    const liq = pairs[i].liquidity?.usd ?? 0
    if (liq > bestLiq) {
      best = pairs[i]
      bestLiq = liq
    }
  }
  return best
}
