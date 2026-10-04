import { describe, it, expect } from 'vitest'

import { heicExif, withExif } from './exifCarry'

// A big-endian TIFF block. Its IFD0 holds one Orientation tag (6: rotate
// 90 degrees), which is the value in a portrait photo from an iPhone.
function tiffWithOrientation(orientation: number): Uint8Array {
  const tiff = new Uint8Array(8 + 2 + 12 + 4)
  const view = new DataView(tiff.buffer)
  tiff.set([0x4d, 0x4d, 0x00, 0x2a])
  view.setUint32(4, 8)
  view.setUint16(8, 1)
  view.setUint16(10, 0x0112)
  view.setUint16(12, 3) // SHORT
  view.setUint32(14, 1)
  view.setUint16(18, orientation)
  return tiff
}

const bytes = (...parts: (number[] | Uint8Array | string)[]) =>
  Uint8Array.from(
    parts.flatMap(part =>
      typeof part === 'string'
        ? [...part].map(char => char.charCodeAt(0))
        : [...part]
    )
  )

describe('exifCarry', () => {
  it('finds the TIFF block of a HEIC Exif item', () => {
    const tiff = tiffWithOrientation(6)
    const heic = bytes('\0\0\0\x18ftypheic', [0, 0, 0, 6], 'Exif\0\0', tiff)

    expect(heicExif(heic)).toEqual(tiff)
  })

  it('ignores an "Exif" marker not followed by a TIFF header', () => {
    expect(heicExif(bytes('ftypheic', 'Exif\0\0', 'garbage!'))).toBeNull()
  })

  it('inserts the block as APP1 right after SOI, upright', () => {
    const jpeg = bytes([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x02, 0xff, 0xd9])
    const out = withExif(jpeg, tiffWithOrientation(6))

    // SOI, APP1 marker, then the segment length (2 + 6 + 26 = 34).
    expect([...out.slice(0, 6)]).toEqual([0xff, 0xd8, 0xff, 0xe1, 0, 34])
    expect(String.fromCharCode(...out.slice(6, 10))).toBe('Exif')
    // The original JPEG body comes after the segment, with no change.
    expect([...out.slice(-6)]).toEqual([0xff, 0xdb, 0x00, 0x02, 0xff, 0xd9])
    // The function reset the Orientation value (TIFF offset 18) from 6 to 1.
    const tiffStart = 12
    expect(out[tiffStart + 18] * 256 + out[tiffStart + 19]).toBe(1)
  })

  it('leaves a non-JPEG untouched', () => {
    const png = bytes([0x89, 0x50, 0x4e, 0x47])
    expect(withExif(png, tiffWithOrientation(1))).toBe(png)
  })
})
