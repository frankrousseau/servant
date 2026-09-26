import { describe, it, expect } from 'vitest'

import { flawsOf, measure } from './quality'

// A width x height RGBA frame whose gray level comes from `level(x, y)`.
function frame(
  width: number,
  height: number,
  level: (x: number, y: number) => number
) {
  const pixels = new Uint8ClampedArray(width * height * 4)
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4
      pixels.fill(level(x, y), i, i + 3)
      pixels[i + 3] = 255
    }
  }
  return measure(pixels, width, height)
}

describe('photo quality', () => {
  it('passes a sharp, well exposed frame', () => {
    // A checkerboard: strong edges everywhere, mid-gray on average.
    const metrics = frame(64, 64, (x, y) =>
      ((x >> 2) + (y >> 2)) % 2 ? 200 : 60
    )
    expect(flawsOf(metrics)).toEqual([])
  })

  it('flags a flat, edgeless frame as blurry', () => {
    const metrics = frame(64, 64, x => 100 + x * 0.5)
    expect(flawsOf(metrics)).toEqual(['blurry'])
  })

  it('names a black frame dark, not blurry', () => {
    expect(flawsOf(frame(64, 64, () => 8))).toEqual(['dark'])
  })

  it('names a blown-out frame overexposed', () => {
    const metrics = frame(64, 64, (x, y) => ((x + y) % 2 ? 255 : 252))
    expect(flawsOf(metrics)).toEqual(['overexposed'])
  })
})
