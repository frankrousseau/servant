import { ref } from 'vue'
import type { AppContext, Entry } from '../types'

// Module-level upload queue: uploads must survive navigating to another app
// (drop 200 photos, go do something else). The PhotosApp component reads
// these refs while mounted; the worker loop below runs regardless.

type PhotosApi = AppContext['api']

export interface UploadProgress {
  index: number
  total: number
  name: string
  pct: number // whole-batch progress in bytes
  converting: boolean // decoding HEIC in the browser before sending
  processing: boolean // bytes sent, waiting on server work (thumbnails, EXIF…)
}

export const uploading = ref(false)
export const uploadProgress = ref<UploadProgress | null>(null)
// One entry per failed file; a failure never aborts the rest of the batch.
export const uploadErrors = ref<string[]>([])
// Last entry created by the worker: a mounted PhotosApp watches it to insert
// the photo into its grid without a full reload.
export const lastCreated = ref<Entry | null>(null)
// Bumped when the queue drains: a mounted PhotosApp watches it to true-up.
export const batchesDone = ref(0)

interface QueueItem {
  file: File
  album: string | null
  api: PhotosApi
}

const queue: QueueItem[] = []
let batchTotal = 0
let batchIndex = 0
let totalBytes = 0
let doneBytes = 0

export const isHeic = (f: File) =>
  /\.(heic|heif)$/i.test(f.name) ||
  f.type === 'image/heic' ||
  f.type === 'image/heif'

// The bundled server-side libvips can't decode HEVC, and neither can most
// browsers: decode HEIC to JPEG in the browser (wasm, lazy-loaded only when
// a HEIC is actually picked). ponytail: the original HEIC is not kept (the
// JPEG becomes the archived file); revisit if originals matter.
async function toUploadable(file: File): Promise<File> {
  if (!isHeic(file)) return file
  const { default: heic2any } = await import('heic2any')
  const blob = (await heic2any({
    blob: file,
    toType: 'image/jpeg',
    quality: 0.9
  })) as Blob
  return new File([blob], file.name.replace(/\.(heic|heif)$/i, '.jpg'), {
    type: 'image/jpeg'
  })
}

// Grid thumbnail for videos: decode in the browser (no server-side ffmpeg),
// seek to the middle (first frames are often black) and grab a small JPEG.
// null when the browser can't decode the codec; the grid shows a play tile.
export function captureVideoFrame(file: File): Promise<File | null> {
  return new Promise(resolve => {
    const url = URL.createObjectURL(file)
    const video = document.createElement('video')
    let settled = false
    const done = (out: File | null) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      URL.revokeObjectURL(url)
      video.removeAttribute('src')
      resolve(out)
    }
    // ponytail: 15s cap so an undecodable file can't hang the upload loop
    const timer = setTimeout(() => done(null), 15_000)
    video.muted = true
    video.playsInline = true
    video.preload = 'metadata'
    video.onerror = () => done(null)
    video.onloadedmetadata = () => {
      video.currentTime =
        Number.isFinite(video.duration) && video.duration > 0
          ? video.duration / 2
          : 0
    }
    video.onseeked = () => {
      const w = video.videoWidth
      const h = video.videoHeight
      if (!w || !h) return done(null)
      const scale = Math.min(1, 400 / w)
      const canvas = document.createElement('canvas')
      canvas.width = Math.round(w * scale)
      canvas.height = Math.round(h * scale)
      canvas
        .getContext('2d')
        ?.drawImage(video, 0, 0, canvas.width, canvas.height)
      canvas.toBlob(
        blob =>
          done(
            blob
              ? new File(
                  [blob],
                  file.name.replace(/\.[^.]+$/, '') + '_thumb.jpg',
                  {
                    type: 'image/jpeg'
                  }
                )
              : null
          ),
        'image/jpeg',
        0.8
      )
    }
    video.src = url
  })
}

// Files dropped while a batch is running join the same batch: totals grow,
// the single worker keeps going.
export function enqueueUploads(
  files: File[],
  api: PhotosApi,
  album: string | null
) {
  // .heic often comes with an empty/octet-stream type outside Safari: match by name too.
  const media = files.filter(
    f =>
      f.type.startsWith('image/') ||
      f.type.startsWith('video/') ||
      /\.(heic|heif)$/i.test(f.name)
  )
  if (!media.length) return
  for (const f of media) queue.push({ file: f, album, api })
  batchTotal += media.length
  totalBytes += media.reduce((sum, f) => sum + f.size, 0)
  if (!uploading.value) void runQueue()
}

async function runQueue() {
  uploading.value = true
  uploadErrors.value = []
  while (queue.length) {
    const item = queue.shift()!
    batchIndex++
    await processItem(item)
  }
  uploadProgress.value = null
  uploading.value = false
  batchTotal = 0
  batchIndex = 0
  totalBytes = 0
  doneBytes = 0
  batchesDone.value++
}

async function processItem({ file: original, album, api }: QueueItem) {
  uploadProgress.value = {
    index: batchIndex,
    total: batchTotal,
    name: original.name,
    pct: Math.round((doneBytes / (totalBytes || 1)) * 100),
    converting: isHeic(original),
    processing: false
  }
  try {
    const file = await toUploadable(original)
    if (uploadProgress.value) uploadProgress.value.converting = false
    const result = (await api.upload(file, 'photos', pct => {
      if (uploadProgress.value) {
        // Weight by the original size: totalBytes was computed from the
        // picked files, before any HEIC to JPEG conversion.
        uploadProgress.value.total = batchTotal
        uploadProgress.value.pct = Math.round(
          ((doneBytes + (pct / 100) * original.size) / (totalBytes || 1)) * 100
        )
        uploadProgress.value.processing = pct >= 100
      }
    })) as unknown as Record<string, unknown>
    doneBytes += original.size
    const data: Record<string, unknown> = {
      filename: file.name,
      size: result.size,
      mime_type: result.mime_type,
      path: result.path,
      album,
      tags: []
    }
    if (result.date_taken) data.date_taken = result.date_taken
    if (result.latitude != null) {
      data.latitude = result.latitude
      data.longitude = result.longitude
    }
    if (result.camera) data.camera = result.camera
    if (result.thumb_path) data.thumb_path = result.thumb_path
    if (result.display_path) data.display_path = result.display_path

    // Videos: the grid never mounts a <video>, so give it a real image.
    if (((result.mime_type as string) || file.type).startsWith('video/')) {
      const frame = await captureVideoFrame(file)
      if (frame) {
        try {
          const t = (await api.upload(frame, 'photos')) as unknown as Record<
            string,
            unknown
          >
          data.thumb_path = t.path
        } catch {
          // No thumbnail: the grid falls back to the play tile.
        }
      }
    }

    // No EXIF/container date: fall back to the file's mtime, which for
    // phone media is usually the capture time.
    const fallbackDate = original.lastModified
      ? new Date(original.lastModified).toISOString()
      : null

    lastCreated.value = await api.entries.create({
      kind: 'photo',
      source: 'photos_app',
      title: file.name,
      occurred_at: (result.date_taken as string) || fallbackDate,
      data
    })
  } catch (e) {
    doneBytes += original.size
    uploadErrors.value.push(
      `${original.name}: ${e instanceof Error ? e.message : 'upload failed'}`
    )
  }
}
