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

    // One deduplicated Alice-Bob edge; nothing touching me, Carol isolated.
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
        // circle 0 is the opaque underlay; both share cx.
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
    // Quadratic arcs, and the two edges leaving Alice are not the same stroke.
    expect(ds.every(d => d.includes('Q'))).toBe(true)
    expect(ds[0]).not.toBe(ds[1])
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
