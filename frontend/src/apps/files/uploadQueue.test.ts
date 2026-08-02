import { describe, it, expect } from 'vitest'

import {
  batchesDone,
  enqueueUploads,
  uploadErrors,
  uploading
} from './uploadQueue'
import type { Entry } from '../types'

function fakeApi() {
  const created: Entry[] = []
  const api = {
    upload: async (file: File) => ({
      path: '/files/' + file.name,
      mime_type: file.type,
      size: 1
    }),
    entries: {
      create: async (attrs: Record<string, unknown>) => {
        const entry = {
          id: 'id-' + (attrs.title as string),
          kind: 'file',
          source: 'files_app',
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

describe('files uploadQueue', () => {
  it('uploads into the folder captured at enqueue time', async () => {
    const { api, created } = fakeApi()
    const doneBefore = batchesDone.value

    enqueueUploads(
      [new File(['x'], 'report.pdf', { type: 'application/pdf' })],
      api,
      'folder-42'
    )
    await untilIdle()

    expect(created).toHaveLength(1)
    expect(created[0].data.parent_id).toBe('folder-42')
    expect(created[0].data.is_folder).toBe(false)
    expect(uploadErrors.value).toEqual([])
    expect(batchesDone.value).toBe(doneBefore + 1)
  })
})
