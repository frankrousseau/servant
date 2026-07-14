import type { StoredFace } from './faces'

// Browser-side face detection: @vladmandic/face-api (SSD MobileNet detector,
// 68-point landmarks for alignment, 128-d recognition descriptors), loaded
// on first use only (~1.3MB of JS + 12MB of weights served from /models,
// see frontend/public/models). Everything runs locally; no image ever
// leaves the machine.

type FaceApi = typeof import('@vladmandic/face-api')

let loading: Promise<FaceApi> | null = null

function api(): Promise<FaceApi> {
  if (!loading) {
    loading = import('@vladmandic/face-api').then(async f => {
      await Promise.all([
        f.nets.ssdMobilenetv1.loadFromUri('/models'),
        f.nets.faceLandmark68Net.loadFromUri('/models'),
        f.nets.faceRecognitionNet.loadFromUri('/models')
      ])
      return f
    })
    // A failed load (offline, missing models) retries on the next call.
    loading.catch(() => {
      loading = null
    })
  }
  return loading
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error('image failed to load'))
    img.src = src
  })
}

const round4 = (n: number) => Math.round(n * 10_000) / 10_000

// Detects faces on an image URL (the photo's display JPEG). Returns the
// storable face records; [] when no face is found.
export async function detectFaces(src: string): Promise<StoredFace[]> {
  const f = await api()
  const img = await loadImage(src)
  const w = img.naturalWidth || 1
  const h = img.naturalHeight || 1

  const detections = await f
    .detectAllFaces(img, new f.SsdMobilenetv1Options({ minConfidence: 0.5 }))
    .withFaceLandmarks()
    .withFaceDescriptors()

  return detections.map(d => ({
    box: [
      round4(d.detection.box.x / w),
      round4(d.detection.box.y / h),
      round4(d.detection.box.width / w),
      round4(d.detection.box.height / h)
    ],
    emb: Array.from(d.descriptor).map(round4)
  }))
}
