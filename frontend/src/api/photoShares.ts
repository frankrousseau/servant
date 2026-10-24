// The share links of the photo feeds. This module has the management calls of
// the owner (session only) and the fetch of the public feed. That fetch does
// not use the app client on purpose: a visitor has no session, and a 404
// there must not log out a user.
import type { PhotoShare, SharedFeed } from '../types'
import { apiJson } from '../composables/apiClient'

export async function listPhotoShares(): Promise<PhotoShare[]> {
  const res = await apiJson<{ data: PhotoShare[] }>('GET', '/api/photo_shares')
  return res.data
}

export async function createPhotoShare(attrs: {
  name?: string
  tags: string[]
  match: 'any' | 'all'
}): Promise<PhotoShare> {
  const res = await apiJson<{ data: PhotoShare }>('POST', '/api/photo_shares', {
    body: attrs
  })
  return res.data
}

export function deletePhotoShare(id: string): Promise<void> {
  return apiJson<void>('DELETE', `/api/photo_shares/${id}`)
}

/** Resolves to null when the link is unknown or revoked. */
export async function fetchSharedFeed(
  token: string
): Promise<SharedFeed | null> {
  const res = await fetch(`/api/shares/${encodeURIComponent(token)}`, {
    headers: { Accept: 'application/json' }
  })
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`Request failed: ${res.status}`)
  return res.json()
}
