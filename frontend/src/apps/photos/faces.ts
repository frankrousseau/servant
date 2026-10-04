import type { Entry } from '../types'

// Pure logic for face recognition. The detection (faceScan.ts) stores the
// faces on the photo entries as data.faces. This module clusters the unnamed
// faces and matches the clusters against the confirmed people. As a result,
// when the user names one cluster, the name tags every photo that the
// cluster appears in. The embeddings are face-api 128-d descriptors. Two
// shots of the same person are at a euclidean distance of approximately 0.5
// or less.

export interface StoredFace {
  box: number[] // [x, y, w, h] relative to the image (0..1)
  emb: number[] // 128-d descriptor
  person_id?: string
}

export const FACE_MATCH_DISTANCE = 0.5
// The number of references kept for each person for the match. It is
// satisfactory to keep the newest ones first. More references add noise and
// cost, not accuracy.
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

// A face together with its location. The location lets the code update the
// photo entry when the user names the face.
export interface FaceRef {
  photoId: string
  index: number
  face: StoredFace
}

// Maps each person_id to its reference embeddings, from the confirmed faces.
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
  // The nearest known person at a distance less than FACE_MATCH_DISTANCE, if
  // there is one.
  suggestedPersonId?: string
}

// Greedy centroid clustering of the unnamed faces. The result depends on the
// order and the cost is O(faces * clusters). This is sufficient for the size
// of a personal library.
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
