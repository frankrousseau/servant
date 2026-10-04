import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import RelationsGraph from './RelationsGraph.vue'

import type { Entry } from '../types'

function contact(
  id: string,
  name: string,
  relations: { contact_id: string; type: string }[] = []
): Entry {
  return {
    id,
    kind: 'contact',
    source: 'test',
    external_id: null,
    title: name,
    occurred_at: null,
    data: { display_name: name, relations },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('RelationsGraph', () => {
  it('draws relation edges but leaves out links to me', async () => {
    const contacts = [
      contact('me', 'Frank', [{ contact_id: 'a', type: 'friend' }]),
      contact('a', 'Alice', [
        { contact_id: 'me', type: 'friend' },
        { contact_id: 'b', type: 'sibling' }
      ]),
      contact('b', 'Bob', [{ contact_id: 'a', type: 'sibling' }]),
      contact('c', 'Carol')
    ]
    const wrapper = mount(RelationsGraph, {
      props: { contacts, meId: 'me' }
    })

    // There is one deduplicated Alice-Bob edge. No edge touches me, and Carol
    // is isolated.
    expect(wrapper.findAll('.rg-edge')).toHaveLength(1)
    const labels = wrapper.findAll('.rg-label').map(l => l.text())
    expect(labels.sort()).toEqual(['Alice', 'Bob'])

    await wrapper.findAll('.rg-node')[0].trigger('click')
    expect(wrapper.emitted('select')![0]).toEqual([
      wrapper.findAll('.rg-label')[0].text() === 'Alice' ? 'a' : 'b'
    ])
  })

  it('keeps disconnected groups in separate regions', () => {
    const contacts = [
      contact('a', 'Alice', [{ contact_id: 'b', type: 'sibling' }]),
      contact('b', 'Bob', [{ contact_id: 'a', type: 'sibling' }]),
      contact('c', 'Carol', [{ contact_id: 'd', type: 'friend' }]),
      contact('d', 'Dave', [{ contact_id: 'c', type: 'friend' }])
    ]
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    const xs = new Map(
      wrapper.findAll('.rg-node').map(g => [
        g.find('.rg-label').text(),
        // Circle 0 is the opaque underlay. The two circles share cx.
        parseFloat(g.find('circle').attributes('cx')!)
      ])
    )
    const left = Math.max(xs.get('Alice')!, xs.get('Bob')!)
    const right = Math.min(xs.get('Carol')!, xs.get('Dave')!)
    expect(left).toBeLessThan(right)
  })

  it('bows edges apart instead of stacking straight lines', () => {
    const contacts = [
      contact('a', 'Alice', [
        { contact_id: 'b', type: 'sibling' },
        { contact_id: 'c', type: 'friend' }
      ]),
      contact('b', 'Bob', [{ contact_id: 'a', type: 'sibling' }]),
      contact('c', 'Carol', [{ contact_id: 'a', type: 'friend' }])
    ]
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    const ds = wrapper.findAll('.rg-edge').map(e => e.attributes('d')!)
    expect(ds).toHaveLength(2)
    // The edges are quadratic arcs, and the two edges that leave Alice are not
    // the same stroke.
    expect(ds.every(d => d.includes('Q'))).toBe(true)
    expect(ds[0]).not.toBe(ds[1])
  })

  // Returns the signed distance from the chord's midpoint to the arc's
  // control point: how far, and in which direction, an edge bows.
  function bowOf(d: string): number {
    const [x0, y0, cx, cy, x1, y1] = d.match(/-?\d+(\.\d+)?/g)!.map(Number)
    const vx = x1 - x0
    const vy = y1 - y0
    const length = Math.hypot(vx, vy) || 1
    return (vx * (cy - (y0 + y1) / 2) - vy * (cx - (x0 + x1) / 2)) / length
  }

  it('gives every edge of a fan its own bow, so none can stack', () => {
    const spokes = ['b', 'c', 'd', 'e']
    const contacts = [
      contact(
        'a',
        'Alice',
        spokes.map(id => ({ contact_id: id, type: 'friend' }))
      ),
      ...spokes.map(id =>
        contact(id, id.toUpperCase(), [{ contact_id: 'a', type: 'friend' }])
      )
    ]
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    const bows = wrapper
      .findAll('.rg-edge')
      .map(edge => bowOf(edge.attributes('d')!))
    expect(bows).toHaveLength(4)
    // The slots are centered (-1.5, -0.5, +0.5, +1.5). Two edges bow in each
    // direction, and the outer pair bows approximately three times as wide as
    // the inner pair. If the code selects only a side for each edge, every
    // edge gets the same width.
    expect(bows.filter(bow => bow > 0)).toHaveLength(2)
    const widths = bows.map(Math.abs)
    expect(Math.max(...widths) / Math.min(...widths)).toBeGreaterThan(2)
  })

  it('moves nodes aside so no edge runs over an unrelated contact', () => {
    // A wheel: a hub is tied to six friends who also form a ring. This gives
    // many occasions for an edge to cut across a disc that it does not touch.
    const ring = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5']
    const contacts = [
      contact(
        'hub',
        'Hub',
        ring.map(id => ({ contact_id: id, type: 'friend' }))
      ),
      ...ring.map((id, i) =>
        contact(id, `Ring ${id.toUpperCase()}`, [
          { contact_id: 'hub', type: 'friend' },
          { contact_id: ring[(i + 1) % ring.length], type: 'colleague' }
        ])
      )
    ]
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    const centers = wrapper.findAll('.rg-node').map(node => ({
      x: parseFloat(node.find('circle').attributes('cx')!),
      y: parseFloat(node.find('circle').attributes('cy')!)
    }))
    const offenses: string[] = []
    for (const edge of wrapper.findAll('.rg-edge')) {
      const [x0, y0, cx, cy, x1, y1] = edge
        .attributes('d')!
        .match(/-?\d+(\.\d+)?/g)!
        .map(Number)
      for (let step = 0; step <= 20; step++) {
        const t = step / 20
        const u = 1 - t
        const px = u * u * x0 + 2 * u * t * cx + t * t * x1
        const py = u * u * y0 + 2 * u * t * cy + t * t * y1
        for (const center of centers) {
          // Paths already start 17px out of their own endpoint discs, so a
          // sample closer than 16 to any center means the arc crosses a disc.
          if (Math.hypot(px - center.x, py - center.y) < 16) {
            offenses.push(
              `${edge.attributes('d')} at t=${t} near ${center.x},${center.y}`
            )
          }
        }
      }
    }
    expect(offenses).toEqual([])
  })

  it('keeps every disc and name clear of the others, however crowded', () => {
    // Three families of a parent and seven children. There are enough nodes
    // that the old fixed 900x620 canvas piled them up on top of each other.
    const contacts: Entry[] = []
    const families = ['Durand', 'Martin', 'Lefebvre']
    families.forEach((family, familyIndex) => {
      const parent = `${family.toLowerCase()}-parent`
      const memberIds = Array.from(
        { length: 7 },
        (_unused, i) => `${family.toLowerCase()}-${i}`
      )
      contacts.push(
        contact(
          parent,
          `Parent ${family}`,
          memberIds.map(id => ({ contact_id: id, type: 'child' }))
        )
      )
      memberIds.forEach((id, i) => {
        contacts.push(
          contact(id, `${family} Number${familyIndex}${i}`, [
            { contact_id: parent, type: 'parent' }
          ])
        )
      })
    })
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    interface Box {
      name: string
      left: number
      right: number
      top: number
      bottom: number
    }
    const boxes: Box[] = wrapper.findAll('.rg-node').map(node => {
      const name = node.find('.rg-label').text()
      const x = parseFloat(node.find('circle').attributes('cx')!)
      const y = parseFloat(node.find('circle').attributes('cy')!)
      // Disc (r=14) plus the name centered 28px below it, 11px mono font.
      const halfWidth = Math.max(18, name.length * 3.3 + 4)
      return {
        name,
        left: x - halfWidth,
        right: x + halfWidth,
        top: y - 18,
        bottom: y + 34
      }
    })
    expect(boxes).toHaveLength(24)
    const collisions: string[] = []
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i]
        const b = boxes[j]
        if (
          a.left < b.right &&
          b.left < a.right &&
          a.top < b.bottom &&
          b.top < a.bottom
        ) {
          collisions.push(`${a.name} / ${b.name}`)
        }
      }
    }
    expect(collisions).toEqual([])
  })

  it('sizes the canvas to the graph instead of squeezing into it', () => {
    const spokes = Array.from({ length: 60 }, (_unused, i) => `s${i}`)
    const contacts = [
      contact(
        'hub',
        'Hub',
        spokes.map(id => ({ contact_id: id, type: 'friend' }))
      ),
      ...spokes.map(id =>
        contact(id, `Contact ${id.toUpperCase()}`, [
          { contact_id: 'hub', type: 'friend' }
        ])
      )
    ]
    const wrapper = mount(RelationsGraph, { props: { contacts, meId: null } })

    const svg = wrapper.find('svg')
    // The svg renders 1:1 (the width and the height in px match the viewBox).
    // As a result, a large network scrolls at a readable size and does not
    // scale down to fit.
    const [, , viewWidth, viewHeight] = svg
      .attributes('viewBox')!
      .split(' ')
      .map(Number)
    expect(parseFloat(svg.attributes('width')!)).toBe(viewWidth)
    expect(parseFloat(svg.attributes('height')!)).toBe(viewHeight)
    // 61 labeled nodes cannot stay legible inside the old fixed 900x620.
    expect(viewWidth * viewHeight).toBeGreaterThan(900 * 620)
  })

  it('explains itself when no inter-contact relation exists', () => {
    const wrapper = mount(RelationsGraph, {
      props: {
        contacts: [
          contact('me', 'Frank'),
          contact('a', 'Alice', [{ contact_id: 'me', type: 'friend' }])
        ],
        meId: 'me'
      }
    })
    expect(wrapper.find('.rg-empty').text()).toContain('No relations')
    expect(wrapper.find('svg').exists()).toBe(false)
  })
})
