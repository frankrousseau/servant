// Finds the failed shots, in the browser and from the thumbnail only. A
// blurry, dark or overexposed photo shows its flaw also at 400px. The
// sharpness is the variance of the Laplacian: edges make it high, blur makes
// it low. The exposure is the mean luminance plus the share of crushed or
// clipped pixels.
// ponytail: the thresholds are fixed and tuned on phone photos. They are the
// values to adjust if a camera or a style (night shots, snow) triggers them
// too often. "Keep" permanently solves a false positive.

export interface QualityMetrics {
  sharpness: number
  brightness: number // mean luminance, 0-255
  shadows: number // share of pixels at or under SHADOW_LEVEL
  highlights: number // share of pixels at or over HIGHLIGHT_LEVEL
}

export type Flaw = 'blurry' | 'dark' | 'overexposed'

export const FLAW_LABELS: Record<Flaw, string> = {
  blurry: 'Blurry',
  dark: 'Too dark',
  overexposed: 'Overexposed'
}

const SHARPNESS_MIN = 60
const DARK_BRIGHTNESS = 45
const DARK_SHADOWS = 0.6
const BRIGHT_BRIGHTNESS = 225
const BRIGHT_HIGHLIGHTS = 0.4
const SHADOW_LEVEL = 20
const HIGHLIGHT_LEVEL = 250
// The size for the analysis. It gives sufficient detail for the Laplacian and
// has a low cost on all machines.
const MAX_SIDE = 320

const round = (value: number) => Math.round(value * 1000) / 1000

export function measure(
  pixels: Uint8ClampedArray,
  width: number,
  height: number
): QualityMetrics {
  const luma = new Float32Array(width * height)
  let sum = 0
  let shadows = 0
  let highlights = 0
  for (let i = 0; i < luma.length; i++) {
    const value =
      0.299 * pixels[i * 4] +
      0.587 * pixels[i * 4 + 1] +
      0.114 * pixels[i * 4 + 2]
    luma[i] = value
    sum += value
    if (value <= SHADOW_LEVEL) shadows++
    if (value >= HIGHLIGHT_LEVEL) highlights++
  }

  let lapSum = 0
  let lapSqSum = 0
  let count = 0
  for (let y = 1; y < height - 1; y++) {
    for (let x = 1; x < width - 1; x++) {
      const i = y * width + x
      const lap =
        4 * luma[i] -
        luma[i - 1] -
        luma[i + 1] -
        luma[i - width] -
        luma[i + width]
      lapSum += lap
      lapSqSum += lap * lap
      count++
    }
  }
  const lapMean = count ? lapSum / count : 0
  const total = luma.length || 1
  return {
    sharpness: round(count ? lapSqSum / count - lapMean * lapMean : 0),
    brightness: round(sum / total),
    shadows: round(shadows / total),
    highlights: round(highlights / total)
  }
}

export function flawsOf(metrics: QualityMetrics): Flaw[] {
  const flaws: Flaw[] = []
  const dark =
    metrics.brightness < DARK_BRIGHTNESS || metrics.shadows > DARK_SHADOWS
  const overexposed =
    metrics.brightness > BRIGHT_BRIGHTNESS ||
    metrics.highlights > BRIGHT_HIGHLIGHTS
  // A frame that is almost black or almost white has almost no edges. Report
  // only its exposure flaw, and not the focus too.
  if (metrics.sharpness < SHARPNESS_MIN && !dark && !overexposed)
    flaws.push('blurry')
  if (dark) flaws.push('dark')
  if (overexposed) flaws.push('overexposed')
  return flaws
}

export function measureImage(src: string): Promise<QualityMetrics> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => {
      const scale = Math.min(1, MAX_SIDE / Math.max(img.width, img.height))
      const width = Math.max(1, Math.round(img.width * scale))
      const height = Math.max(1, Math.round(img.height * scale))
      const canvas = document.createElement('canvas')
      canvas.width = width
      canvas.height = height
      const context = canvas.getContext('2d')
      if (!context) return reject(new Error('no canvas support'))
      context.drawImage(img, 0, 0, width, height)
      resolve(
        measure(context.getImageData(0, 0, width, height).data, width, height)
      )
    }
    img.onerror = () => reject(new Error('image failed to load'))
    img.src = src
  })
}
