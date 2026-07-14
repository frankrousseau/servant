import type { Entry } from '../types'

// Pure logic for face recognition. Detection (faceScan.ts) stores faces on
// photo entries as data.faces; here we cluster the unnamed ones and match
// clusters against people already confirmed, so naming one cluster tags
// every photo it appears in. Embeddings are face-api 128-d descriptors:
// two shots of the same person sit within euclidean distance ~0.5.

export interface StoredFace {
  box: number[] // [x, y, w, h] relative to the image (0..1)
  emb: number[] // 128-d descriptor
  person_id?: string
}

export const FACE_MATCH_DISTANCE = 0.5
// References kept per person when matching (newest first is fine; more adds
// noise and cost, not accuracy).
const MAX_REFS = 20

export function faceDistance(a: number[], b: number[]): number {
  let sum = 0
  for (let i = 0; i < a.length; i++) {
    const d = a[i] - b[i]
    sum += d * d
  }
  return Math.sqrt(sum)
}

export function facesOf(photo: Entry): StoredFace[] {
  const faces = photo.data.faces
  return Array.isArray(faces) ? (faces as StoredFace[]) : []
}

// A face plus where it lives, so naming it can update its photo entry.
export interface FaceRef {
  photoId: string
  index: number
  face: StoredFace
}

// person_id -> reference embeddings, from faces already confirmed.
export function namedReferences(photos: Entry[]): Map<string, number[][]> {
  const refs = new Map<string, number[][]>()
  for (const p of photos) {
    for (const f of facesOf(p)) {
      if (!f.person_id || !f.emb?.length) continue
      const list = refs.get(f.person_id) || []
      if (list.length < MAX_REFS) {
        list.push(f.emb)
        refs.set(f.person_id, list)
      }
    }
  }
  return refs
}

export interface FaceCluster {
  faces: FaceRef[]
  centroid: number[]
  // Closest known person within FACE_MATCH_DISTANCE, if any.
  suggestedPersonId?: string
}

// Greedy centroid clustering of the unnamed faces: order-dependent and
// O(faces * clusters), plenty at personal-library scale.
export function clusterFaces(
  photos: Entry[],
  refs: Map<string, number[][]>
): FaceCluster[] {
  const clusters: FaceCluster[] = []

  for (const p of photos) {
    facesOf(p).forEach((face, index) => {
      if (face.person_id || !face.emb?.length) return
      const ref: FaceRef = { photoId: p.id, index, face }

      let best: FaceCluster | null = null
      let bestDist = FACE_MATCH_DISTANCE
      for (const c of clusters) {
        const d = faceDistance(c.centroid, face.emb)
        if (d < bestDist) {
          best = c
          bestDist = d
        }
      }

      if (best) {
        best.faces.push(ref)
        const n = best.faces.length
        best.centroid = best.centroid.map(
          (v, i) => v + (face.emb[i] - v) / n // running mean
        )
      } else {
        clusters.push({ faces: [ref], centroid: [...face.emb] })
      }
    })
  }

  for (const c of clusters) {
    let bestId: string | undefined
    let bestDist = FACE_MATCH_DISTANCE
    for (const [personId, embs] of refs) {
      for (const emb of embs) {
        const d = faceDistance(c.centroid, emb)
        if (d < bestDist) {
          bestId = personId
          bestDist = d
        }
      }
    }
    c.suggestedPersonId = bestId
  }

  return clusters.sort((a, b) => b.faces.length - a.faces.length)
}
