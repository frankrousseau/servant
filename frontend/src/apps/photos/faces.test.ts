import { describe, it, expect } from 'vitest'
import {
  clusterFaces,
  faceDistance,
  facesOf,
  namedReferences,
  type StoredFace
} from './faces'
import type { Entry } from '../types'

// Toy embeddings: the vectors of the same person are near, the vectors of
// different persons are far. Real descriptors are 128-d, but the logic uses
// only the distances.
const alice = (jitter = 0) => [1 + jitter, 0, 0]
const bob = (jitter = 0) => [0, 1 + jitter, 0]

function photo(id: string, faces: StoredFace[]): Entry {
  return {
    id,
    kind: 'photo',
    source: 'upload',
    external_id: null,
    title: null,
    occurred_at: null,
    data: { faces },
    metadata: {},
    inserted_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z'
  }
}

describe('faceDistance', () => {
  it('is the euclidean distance', () => {
    expect(faceDistance([0, 0], [3, 4])).toBe(5)
  })
})

describe('facesOf', () => {
  it('returns [] when the key is absent or malformed', () => {
    expect(facesOf(photo('p', []))).toEqual([])
    const bad = photo('p', [])
    bad.data.faces = 'nope'
    expect(facesOf(bad)).toEqual([])
  })
})

describe('clusterFaces', () => {
  it('groups the same person across photos, splits different people', () => {
    const photos = [
      photo('p1', [{ box: [0, 0, 0.1, 0.1], emb: alice() }]),
      photo('p2', [
        { box: [0, 0, 0.1, 0.1], emb: alice(0.01) },
        { box: [0.5, 0, 0.1, 0.1], emb: bob() }
      ]),
      photo('p3', [{ box: [0, 0, 0.1, 0.1], emb: bob(0.02) }])
    ]
    const clusters = clusterFaces(photos, new Map())
    expect(clusters).toHaveLength(2)
    // The clusters are sorted by size, largest first. Here the two clusters
    // have 2 faces, and the insertion order breaks the tie.
    expect(clusters[0].faces).toHaveLength(2)
    expect(clusters[1].faces).toHaveLength(2)
    const ids = clusters[0].faces.map(f => f.photoId)
    expect(ids).toContain('p1')
    expect(ids).toContain('p2')
  })

  it('skips already-named faces and suggests known people', () => {
    const photos = [
      photo('p1', [
        { box: [0, 0, 0.1, 0.1], emb: alice(), person_id: 'c-alice' }
      ]),
      photo('p2', [{ box: [0, 0, 0.1, 0.1], emb: alice(0.01) }]),
      photo('p3', [{ box: [0, 0, 0.1, 0.1], emb: bob() }])
    ]
    const refs = namedReferences(photos)
    expect([...refs.keys()]).toEqual(['c-alice'])

    const clusters = clusterFaces(photos, refs)
    expect(clusters).toHaveLength(2)
    const aliceCluster = clusters.find(c => c.faces[0].photoId === 'p2')!
    expect(aliceCluster.suggestedPersonId).toBe('c-alice')
    const bobCluster = clusters.find(c => c.faces[0].photoId === 'p3')!
    expect(bobCluster.suggestedPersonId).toBeUndefined()
  })
})
