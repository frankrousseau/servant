import { describe, it, expect } from 'vitest'

import {
  batchesDone,
  enqueueUploads,
  lastCreated,
  uploadErrors,
  uploading
} from './uploadQueue'
import type { Entry } from '../types'

function png(name: string): File {
  return new File(['x'], name, { type: 'image/png' })
}

function fakeApi(failFor: string[] = []) {
  const created: Entry[] = []
  const api = {
    upload: async (file: File) => {
      if (failFor.includes(file.name)) throw new Error('boom')
      return { path: '/files/' + file.name, mime_type: file.type, size: 1 }
    },
    entries: {
      create: async (attrs: Record<string, unknown>) => {
        const entry = {
          id: 'id-' + (attrs.title as string),
          kind: 'photo',
          source: 'photos_app',
          external_id: null,
          title: attrs.title as string,
          occurred_at: null,
          data: attrs.data as Record<string, unknown>,
          metadata: {},
          inserted_at: '2026-01-01T00:00:00Z',
          updated_at: '2026-01-01T00:00:00Z'
        } as Entry
        created.push(entry)
        return entry
      }
    }
  }
  return { api: api as never, created }
}

async function untilIdle() {
  while (uploading.value) await new Promise(r => setTimeout(r, 5))
}

describe('uploadQueue', () => {
  it('uploads a batch and reports completion', async () => {
    const { api, created } = fakeApi()
    const doneBefore = batchesDone.value

    enqueueUploads([png('a.png'), png('b.png')], api, 'Holidays')
    expect(uploading.value).toBe(true)
    await untilIdle()

    expect(created.map(e => e.title)).toEqual(['a.png', 'b.png'])
    expect(created[0].data.album).toBe('Holidays')
    expect(uploadErrors.value).toEqual([])
    expect(lastCreated.value?.title).toBe('b.png')
    expect(batchesDone.value).toBe(doneBefore + 1)
  })

  it('records per-file errors without aborting the batch', async () => {
    const { api, created } = fakeApi(['bad.png'])

    enqueueUploads([png('bad.png'), png('good.png')], api, null)
    await untilIdle()

    expect(created.map(e => e.title)).toEqual(['good.png'])
    expect(uploadErrors.value).toEqual(['bad.png: boom'])
  })

  it('ignores non-media files entirely', () => {
    const { api } = fakeApi()
    enqueueUploads(
      [new File(['x'], 'notes.txt', { type: 'text/plain' })],
      api,
      null
    )
    expect(uploading.value).toBe(false)
  })
})
