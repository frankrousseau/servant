// Carries a HEIC photo's EXIF (date, location, camera) over to the JPEG the
// browser converts it to: the canvas-based decode keeps pixels only, and the
// server reads a photo's date and position from the file it receives.

// Largest payload an APP1 segment can hold (its length field counts itself
// and the "Exif\0\0" header too).
const APP1_MAX_TIFF = 0xffff - 2 - 6

const EXIF_HEADER = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // "Exif\0\0"
const TIFF_BE = [0x4d, 0x4d, 0x00, 0x2a] // "MM\0*"
const TIFF_LE = [0x49, 0x49, 0x2a, 0x00] // "II*\0"

const matchesAt = (bytes: Uint8Array, at: number, pattern: number[]) =>
  pattern.every((byte, i) => bytes[at + i] === byte)

/**
 * The TIFF block of a HEIC's Exif item, or null. Phones store the item as
 * "Exif\0\0" + TIFF header; the TIFF magic right after the marker rules out
 * a stray match in pixel data.
 * ponytail: a marker scan instead of walking the ISOBMFF boxes (the server
 * does the same); the block is cut at the APP1 limit, which the EXIF of a
 * phone photo stays well under.
 */
export function heicExif(heic: Uint8Array): Uint8Array | null {
  for (let i = 0; i + 10 <= heic.length; i++) {
    if (heic[i] !== 0x45 || !matchesAt(heic, i, EXIF_HEADER)) continue
    const tiff = i + EXIF_HEADER.length
    if (matchesAt(heic, tiff, TIFF_BE) || matchesAt(heic, tiff, TIFF_LE)) {
      return heic.slice(tiff, Math.min(heic.length, tiff + APP1_MAX_TIFF))
    }
  }
  return null
}

/**
 * The converted pixels are already upright: an Orientation tag copied as is
 * would rotate the photo a second time, so IFD0's is set back to 1 (normal).
 */
function withUprightOrientation(tiff: Uint8Array): Uint8Array {
  const out = tiff.slice()
  const view = new DataView(out.buffer)
  const little = out[0] === 0x49
  const ifd0 = view.getUint32(4, little)
  if (ifd0 + 2 > out.length) return out
  const count = view.getUint16(ifd0, little)
  for (let i = 0; i < count; i++) {
    const entry = ifd0 + 2 + i * 12
    if (entry + 12 > out.length) break
    if (view.getUint16(entry, little) === 0x0112) {
      view.setUint16(entry + 8, 1, little)
    }
  }
  return out
}

/** The JPEG with the TIFF block inserted as an APP1 segment after SOI. */
export function withExif(
  jpeg: Uint8Array<ArrayBuffer>,
  tiff: Uint8Array
): Uint8Array<ArrayBuffer> {
  if (jpeg[0] !== 0xff || jpeg[1] !== 0xd8) return jpeg
  const payload = withUprightOrientation(tiff)
  const length = 2 + EXIF_HEADER.length + payload.length
  const out = new Uint8Array(2 + 2 + length + jpeg.length - 2)
  out.set([0xff, 0xd8, 0xff, 0xe1, length >> 8, length & 0xff], 0)
  out.set(EXIF_HEADER, 6)
  out.set(payload, 6 + EXIF_HEADER.length)
  out.set(jpeg.subarray(2), 4 + length)
  return out
}
