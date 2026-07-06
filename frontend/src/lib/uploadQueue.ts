import { ref, type Ref } from 'vue'
import type { Entry } from '../apps/types'

// Generic module-level upload queue. Each app instantiates one at module
// scope so a running batch survives the app's component unmounting (drop
// 200 files, navigate away, come back). The component only reads the refs.

export interface UploadProgress {
  index: number
  total: number
  name: string
  pct: number // whole-batch progress in bytes
  converting: boolean // client-side decode before sending (HEIC)
  processing: boolean // bytes sent, waiting on server work
}

export interface ProcessTools {
  onBytesPct(pct: number): void // per-item transfer progress, 0-100
  setConverting(on: boolean): void
}

export interface UploadQueue<T> {
  uploading: Ref<boolean>
  uploadProgress: Ref<UploadProgress | null>
  uploadErrors: Ref<string[]>
  // Last entry created by the worker: a mounted app watches it to insert
  // the item into its view without a full reload.
  lastCreated: Ref<Entry | null>
  // Bumped when the queue drains: a mounted app watches it to true-up.
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
  // One entry per failed item; a failure never aborts the rest of the batch.
  const uploadErrors = ref<string[]>([])
  const lastCreated = ref<Entry | null>(null)
  const batchesDone = ref(0)

  const queue: T[] = []
  let batchTotal = 0
  let batchIndex = 0
  let totalBytes = 0
  let doneBytes = 0

  // Items enqueued while a batch is running join it: totals grow, the
  // single worker keeps going.
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
        uploadErrors.value.push(
          `${opts.itemName(item)}: ${e instanceof Error ? e.message : 'upload failed'}`
        )
      } finally {
        doneBytes += size
      }
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
