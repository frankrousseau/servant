import type { AppContext, Entry } from '../types'
import { createUploadQueue } from '../../lib/uploadQueue'
import { heicExif, withExif } from './exifCarry'

export type { UploadProgress } from '../../lib/uploadQueue'

// The upload pipeline of Photos, on the shared module-level queue. The
// uploads continue when the user navigates to another app. The browser
// decodes HEIC to JPEG. For each video, the client captures a frame for the
// grid.

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

// The libvips bundled on the server and most browsers cannot decode HEVC.
// Decode HEIC to JPEG in the browser. heic-to bundles a current libheif. The
// old heic2any failed on iOS 18 files. The wasm decode uses seconds of CPU
// for each photo. For this reason, it runs in a Web Worker (heic-to/next,
// lazy-created on the first HEIC), and the tab stays responsive during a
// big batch.
// ponytail: the code does not keep the original HEIC (the JPEG becomes the
// archived file). Look at this again if the originals are important. The
// code copies the EXIF of the HEIC (date, location, camera) into the JPEG,
// because the decode keeps only the pixels.
let heicWorker: Worker | null = null

// A conversion that never settled froze the full batch at "1/N" with no
// error (heic2any did that on iOS 18 files). Set a time limit on the
// conversion. Then the item fails visibly and the batch continues. The code
// builds the worker again, to make sure that the stale decode cannot block
// the next one. 60s is sufficient for a 48MP decode on slow hardware.
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
        // The file is bad but the worker is healthy. Keep the worker for the
        // next item.
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
  const tiff = heicExif(new Uint8Array(await file.arrayBuffer()))
  const jpeg = await convertHeic(file)
  if (!tiff) return jpeg
  const tagged = withExif(new Uint8Array(await jpeg.arrayBuffer()), tiff)
  return new File([tagged], jpeg.name, { type: 'image/jpeg' })
}

// Makes the grid thumbnail of a video. The browser decodes the video, because
// there is no ffmpeg on the server. The function seeks to the middle, because
// the first frames are often black, and gets a small JPEG. It returns null
// when the browser cannot decode the codec. Then the grid shows a play tile.
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
    // ponytail: a time limit of 15s. With this limit, a file that the browser
    // cannot decode cannot block the upload loop.
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
          // There is no thumbnail. The grid shows the play tile as a fallback.
        }
      }
    }

    // There is no EXIF date and no container date. Use the mtime of the file
    // as a fallback. For phone media, the mtime is usually the capture time.
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
  // Outside Safari, a .heic file often has an empty type or an octet-stream
  // type. Also match by name.
  const media = files.filter(
    f =>
      f.type.startsWith('image/') ||
      f.type.startsWith('video/') ||
      /\.(heic|heif)$/i.test(f.name)
  )
  queue.enqueue(media.map(file => ({ file, album, api })))
}
