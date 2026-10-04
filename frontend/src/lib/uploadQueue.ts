import { ref, type Ref } from 'vue'
import type { Entry } from '../apps/types'
import { apiJson } from '../composables/apiClient'

// A generic upload queue at module level. Each app creates one at module
// scope. As a result, a batch in progress survives the unmount of the app
// component (drop 200 files, navigate away, come back). The component only
// reads the refs.

export interface UploadProgress {
  index: number
  total: number
  name: string
  pct: number // whole-batch progress in bytes
  converting: boolean // client-side decode before the upload (HEIC)
  processing: boolean // bytes sent, server work in progress
}

export interface ProcessTools {
  onBytesPct(pct: number): void // per-item transfer progress, 0-100
  setConverting(on: boolean): void
}

export interface UploadQueue<T> {
  uploading: Ref<boolean>
  uploadProgress: Ref<UploadProgress | null>
  uploadErrors: Ref<string[]>
  // The last entry that the worker created. A mounted app watches it to
  // insert the item into its view without a full reload.
  lastCreated: Ref<Entry | null>
  // Increments when the queue is empty again. A mounted app watches it to
  // make its data correct again.
  batchesDone: Ref<number>
  enqueue(items: T[]): void
}

export function createUploadQueue<T>(opts: {
  itemName(item: T): string
  itemSize(item: T): number
  process(item: T, tools: ProcessTools): Promise<Entry>
}): UploadQueue<T> {
  const uploading = ref(false)
  const uploadProgress = ref<UploadProgress | null>(null)
  // One entry for each failed item. A failure never aborts the rest of the
  // batch.
  const uploadErrors = ref<string[]>([])
  const lastCreated = ref<Entry | null>(null)
  const batchesDone = ref(0)

  const queue: T[] = []
  let batchTotal = 0
  let batchIndex = 0
  let totalBytes = 0
  let doneBytes = 0

  // The items that arrive during a batch join that batch: the totals grow,
  // and the single worker continues.
  function enqueue(items: T[]) {
    if (!items.length) return
    queue.push(...items)
    batchTotal += items.length
    totalBytes += items.reduce((sum, it) => sum + opts.itemSize(it), 0)
    if (!uploading.value) void run()
  }

  async function run() {
    uploading.value = true
    uploadErrors.value = []
    while (queue.length) {
      const item = queue.shift()!
      batchIndex++
      const size = opts.itemSize(item)
      uploadProgress.value = {
        index: batchIndex,
        total: batchTotal,
        name: opts.itemName(item),
        pct: Math.round((doneBytes / (totalBytes || 1)) * 100),
        converting: false,
        processing: false
      }
      const tools: ProcessTools = {
        onBytesPct(pct) {
          if (!uploadProgress.value) return
          uploadProgress.value.total = batchTotal
          uploadProgress.value.pct = Math.round(
            ((doneBytes + (pct / 100) * size) / (totalBytes || 1)) * 100
          )
          uploadProgress.value.processing = pct >= 100
        },
        setConverting(on) {
          if (uploadProgress.value) uploadProgress.value.converting = on
        }
      }
      try {
        lastCreated.value = await opts.process(item, tools)
      } catch (e) {
        const message = e instanceof Error ? e.message : 'upload failed'
        uploadErrors.value.push(`${opts.itemName(item)}: ${message}`)
        // Browser-side failures never reach the server by themselves. Mirror
        // them into the Audit error logs. Do not wait for the reply.
        void apiJson('POST', '/api/client_errors', {
          body: {
            context: 'upload',
            message: `${opts.itemName(item)}: ${message}`
          }
        }).catch(() => {})
      } finally {
        doneBytes += size
      }
      // Pause between items so that a big batch cannot starve the render.
      await new Promise(resolve => setTimeout(resolve))
    }
    uploadProgress.value = null
    uploading.value = false
    batchTotal = 0
    batchIndex = 0
    totalBytes = 0
    doneBytes = 0
    batchesDone.value++
  }

  return {
    uploading,
    uploadProgress,
    uploadErrors,
    lastCreated,
    batchesDone,
    enqueue
  }
}
