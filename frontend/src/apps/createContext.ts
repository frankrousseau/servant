import { useRouter } from 'vue-router'

import { useAuthStore } from '../stores/auth'
import type { AppContext, UploadResult, ViewerAPI } from './types'
import { useConfirm } from '../composables/useConfirm'
import { useSocket } from '../composables/useSocket'
import { apiFetch } from '../composables/apiClient'
import {
  aggregateEntries,
  createEntry,
  deleteEntry,
  entryStats,
  getEntry,
  listEntries,
  updateEntry
} from '../api/entries'

export function createAppContext(viewer: ViewerAPI): AppContext {
  const auth = useAuthStore()
  const router = useRouter()
  const { ask } = useConfirm()
  const { onEntryChange } = useSocket()

  return {
    navigate(path: string) {
      router.push(path)
    },
    // Each access reads the current value. As a result, a toggle in Settings
    // reaches a mounted app, and a remount is not necessary.
    get enabledApps() {
      return auth.user?.enabled_apps ?? null
    },
    api: {
      // The app-facing surface is the shared entries client, nothing more.
      entries: {
        list: listEntries,
        get: getEntry,
        create: createEntry,
        update: updateEntry,
        delete: deleteEntry,
        // The plugin contract is the per-kind counts alone.
        stats: async () => (await entryStats()).data,
        aggregate: aggregateEntries
      },
      // The multipart upload keeps its own request. The browser must set the
      // boundary of the multipart Content-Type. And XHR, unlike fetch, can
      // report the upload progress.
      upload(
        file: File,
        app = 'files',
        onProgress?: (pct: number) => void
      ): Promise<UploadResult> {
        const form = new FormData()
        form.append('file', file)
        form.append('app', app)
        return new Promise((resolve, reject) => {
          const xhr = new XMLHttpRequest()
          xhr.open('POST', '/api/uploads')
          if (auth.token)
            xhr.setRequestHeader('Authorization', `Bearer ${auth.token}`)
          xhr.upload.onprogress = e => {
            if (e.lengthComputable && onProgress) {
              onProgress(Math.round((e.loaded / e.total) * 100))
            }
          }
          xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
              try {
                resolve(JSON.parse(xhr.responseText))
              } catch {
                reject(new Error('Invalid server response'))
              }
            } else {
              let msg = 'Upload failed'
              try {
                msg = JSON.parse(xhr.responseText).error || msg
              } catch {
                // Keep the generic message.
              }
              reject(new Error(msg))
            }
          }
          xhr.onerror = () => reject(new Error('Network error during upload'))
          xhr.send(form)
        })
      },
      fetch: apiFetch
    },
    confirm: { ask },
    preferences: {
      get: <T>(key: string, fallback: T) =>
        (auth.user?.preferences?.[key] as T | undefined) ?? fallback,
      set: auth.setPreference
    },
    events: { onEntryChange },
    viewer
  }
}
