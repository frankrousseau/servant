import { describe, it, expect } from 'vitest'

import { crossingCount, untangle, type Link, type Point } from './untangle'

const place = (spots: Record<string, [number, number]>) =>
  new Map<string, Point>(
    Object.entries(spots).map(([id, [x, y]]) => [id, { id, x, y }])
  )

describe('untangle', () => {
  it('swings a branch to the other side of its contact', () => {
    // Carol's relation to Leo cuts straight through Alice - Bob.
    const nodes = place({
      alice: [0, 0],
      bob: [100, 0],
      carol: [50, 40],
      leo: [50, -40]
    })
    const links: Link[] = [
      { from: 'alice', to: 'bob' },
      { from: 'alice', to: 'carol' },
      { from: 'carol', to: 'leo' }
    ]
    expect(crossingCount(nodes, links)).toBe(1)

    untangle(nodes, links)

    expect(crossingCount(nodes, links)).toBe(0)
  })

  it('moves a whole cycle hanging off a contact', () => {
    // The Leo - Mia - Noe triangle hangs off Carol but folds over Alice - Bob.
    const nodes = place({
      alice: [0, 0],
      bob: [200, 0],
      carol: [100, 60],
      leo: [100, -40],
      mia: [60, -90],
      noe: [140, -90]
    })
    const links: Link[] = [
      { from: 'alice', to: 'bob' },
      { from: 'alice', to: 'carol' },
      { from: 'bob', to: 'carol' },
      { from: 'carol', to: 'leo' },
      { from: 'leo', to: 'mia' },
      { from: 'mia', to: 'noe' },
      { from: 'noe', to: 'leo' }
    ]
    expect(crossingCount(nodes, links)).toBeGreaterThan(0)

    untangle(nodes, links)

    expect(crossingCount(nodes, links)).toBe(0)
    // The triangle keeps its shape: rotated as a block around Carol.
    const leo = nodes.get('leo')!
    const mia = nodes.get('mia')!
    expect(Math.hypot(leo.x - mia.x, leo.y - mia.y)).toBeCloseTo(
      Math.hypot(40, 50)
    )
  })

  it('leaves an uncrossed layout alone', () => {
    const nodes = place({ alice: [0, 0], bob: [100, 0], carol: [50, 80] })
    const links: Link[] = [
      { from: 'alice', to: 'bob' },
      { from: 'alice', to: 'carol' }
    ]
    untangle(nodes, links)
    expect(nodes.get('carol')).toEqual({ id: 'carol', x: 50, y: 80 })
  })
})
