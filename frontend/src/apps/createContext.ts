import { useAuthStore } from '../stores/auth'
import { useRouter } from 'vue-router'
import type {
  AggregateBucket,
  AppContext,
  Entry,
  UploadResult,
  ViewerAPI
} from './types'
import { useConfirm } from '../composables/useConfirm'
import { apiFetch, apiJson } from '../composables/apiClient'

export function createAppContext(viewer: ViewerAPI): AppContext {
  const auth = useAuthStore()
  const router = useRouter()
  const { ask } = useConfirm()

  return {
    navigate(path: string) {
      router.push(path)
    },
    api: {
      entries: {
        async list(filters?: Record<string, string>): Promise<Entry[]> {
          // Page through the results instead of a single hardcoded per_page=10000
          // request: that cap silently dropped entries beyond 10k and sent one
          // huge payload. Bounded pages, no cap.
          const perPage = 1000
          const all: Entry[] = []
          let page = 1
          let totalPages = 1
          do {
            const res = await apiJson<{
              data: Entry[]
              meta: { total_pages: number }
            }>('GET', '/api/entries', {
              params: {
                ...(filters || {}),
                per_page: String(perPage),
                page: String(page)
              }
            })
            all.push(...res.data)
            totalPages = res.meta?.total_pages ?? page
            page++
          } while (page <= totalPages)
          return all
        },
        async get(id: string): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>(
            'GET',
            `/api/entries/${id}`
          )
          return res.data
        },
        async create(attrs: Record<string, unknown>): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>('POST', '/api/entries', {
            body: attrs
          })
          return res.data
        },
        async update(
          id: string,
          attrs: Record<string, unknown>
        ): Promise<Entry> {
          const res = await apiJson<{ data: Entry }>(
            'PUT',
            `/api/entries/${id}`,
            { body: attrs }
          )
          return res.data
        },
        async delete(id: string): Promise<void> {
          await apiJson<void>('DELETE', `/api/entries/${id}`)
        },
        async stats(): Promise<Record<string, number>> {
          const res = await apiJson<{ data: Record<string, number> }>(
            'GET',
            '/api/entries/stats'
          )
          return res.data
        },
        async aggregate(
          params: Record<string, string>
        ): Promise<AggregateBucket[]> {
          const res = await apiJson<{ data: AggregateBucket[] }>(
            'GET',
            '/api/entries/aggregate',
            { params }
          )
          return res.data
        }
      },
      // Multipart upload keeps its own request: the browser must set the
      // multipart Content-Type boundary, and XHR (unlike fetch) can report
      // upload progress.
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
                // keep the generic message
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
    viewer
  }
}
