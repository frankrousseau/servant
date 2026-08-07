import { describe, it, expect } from 'vitest'

import { CONNECTOR_DEFS, blockchainConnector } from './connectors'

describe('blockchainConnector', () => {
  it('flags the wallet connectors, hidden while crypto is off', () => {
    const blockchain = CONNECTOR_DEFS.filter(def => blockchainConnector(def.id))
    expect(blockchain.map(def => def.id).sort()).toEqual([
      'arbitrum',
      'base',
      'ethereum',
      'hyperevm',
      'solana'
    ])
  })

  it('leaves the rest alone, unknown ids included', () => {
    expect(blockchainConnector('rss')).toBe(false)
    expect(blockchainConnector('invoice_scraper')).toBe(false)
    expect(blockchainConnector('nope')).toBe(false)
  })
})
