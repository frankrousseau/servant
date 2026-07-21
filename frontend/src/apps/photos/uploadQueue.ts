import type { AppContext, Entry } from '../types'
import { createUploadQueue } from '../../lib/uploadQueue'

export type { UploadProgress } from '../../lib/uploadQueue'

// Photos upload pipeline on the shared module-level queue: uploads survive
// navigating to another app. HEIC decodes to JPEG in the browser, videos get
// a frame captured client-side for the grid.

type PhotosApi = AppContext['api']

interface PhotoUpload {
  file: File
  album: string | null
  api: PhotosApi
}

export const isHeic = (f: File) =>
  /\.(heic|heif)$/i.test(f.name) ||
  f.type === 'image/heic' ||
  f.type === 'image/heif'

// The bundled server-side libvips can't decode HEVC, and neither can most
// browsers: decode HEIC to JPEG in the browser. heic-to bundles a current
// libheif; the old heic2any choked on iOS 18 files. The wasm decode costs
// seconds of CPU per photo, so it runs in a Web Worker (heic-to/next,
// lazy-created on the first HEIC): a big batch keeps the tab responsive.
// ponytail: the original HEIC is not kept (the JPEG becomes the archived
// file); revisit if originals matter.
let heicWorker: Worker | null = null

// A conversion that never settles (heic2any used to do that on iOS 18
// files) froze the whole batch at "1/N" with no error. Cap it so the item
// fails visibly and the batch moves on; the worker is rebuilt so the stale
// decode can't wedge the next one. 60s covers a 48MP decode on slow
// hardware.
function convertHeic(file: File): Promise<File> {
  if (!heicWorker) {
    heicWorker = new Worker(new URL('./heicWorker.ts', import.meta.url), {
      type: 'module'
    })
  }
  const worker = heicWorker
  return new Promise((resolve, reject) => {
    const rebuild = (message: string) => {
      clearTimeout(timer)
      worker.terminate()
      heicWorker = null
      reject(new Error(message))
    }
    const timer = setTimeout(() => rebuild('HEIC conversion timed out'), 60_000)
    worker.onmessage = (e: MessageEvent<{ blob?: Blob; error?: string }>) => {
      clearTimeout(timer)
      if (e.data.error || !e.data.blob) {
        // Bad file, healthy worker: keep it for the next item.
        reject(new Error(e.data.error || 'HEIC conversion failed'))
        return
      }
      resolve(
        new File([e.data.blob], file.name.replace(/\.(heic|heif)$/i, '.jpg'), {
          type: 'image/jpeg'
        })
      )
    }
    worker.onerror = () => rebuild('HEIC conversion failed')
    worker.postMessage({ file })
  })
}

async function toUploadable(file: File): Promise<File> {
  if (!isHeic(file)) return file
  return convertHeic(file)
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

const queue = createUploadQueue<PhotoUpload>({
  itemName: item => item.file.name,
  itemSize: item => item.file.size,
  async process({ file: original, album, api }, tools): Promise<Entry> {
    if (isHeic(original)) tools.setConverting(true)

    let file: File
    try {
      file = await toUploadable(original)
    } finally {
      tools.setConverting(false)
    }
    const result = (await api.upload(
      file,
      'photos',
      tools.onBytesPct
    )) as unknown as Record<string, unknown>
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

    return api.entries.create({
      kind: 'photo',
      source: 'photos_app',
      title: file.name,
      occurred_at: (result.date_taken as string) || fallbackDate,
      data
    })
  }
})

export const {
  uploading,
  uploadProgress,
  uploadErrors,
  lastCreated,
  batchesDone
} = queue

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
  queue.enqueue(media.map(file => ({ file, album, api })))
}
