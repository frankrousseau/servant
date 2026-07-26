// Spot prices for well-known tokens, fetched straight from the browser
// (CoinGecko public API, no key; connect-src allows it). Display info
// only: the curve and totals still go through the manual rates, which
// stay dated by the user.
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

// Symbol -> price in `vs`, for the symbols CoinGecko can identify; the
// others are silently absent. One request for the whole list.
export async function fetchCryptoPrices(
  symbols: string[],
  vs: string
): Promise<Record<string, number>> {
  const wanted = [...new Set(symbols.map(s => s.toUpperCase()))].filter(
    s => s in COINGECKO_IDS
  )
  if (!wanted.length) return {}
  const ids = wanted.map(s => COINGECKO_IDS[s]).join(',')
  const currency = vs.toLowerCase()
  const res = await fetch(
    `https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=${currency}`
  )
  if (!res.ok) return {}
  const body = (await res.json()) as Record<string, Record<string, number>>
  const out: Record<string, number> = {}
  for (const s of wanted) {
    const price = body[COINGECKO_IDS[s]]?.[currency]
    if (typeof price === 'number') out[s] = price
  }
  return out
}
