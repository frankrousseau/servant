// Copies the EXIF of a HEIC photo (date, location, camera) to the JPEG that
// the browser makes from it. The canvas-based decode keeps only the pixels.
// The server reads the date and the position of a photo from the file that
// it receives.

// The largest payload that an APP1 segment can hold. The length field of the
// segment also counts itself and the "Exif\0\0" header.
const APP1_MAX_TIFF = 0xffff - 2 - 6

const EXIF_HEADER = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] // "Exif\0\0"
const TIFF_BE = [0x4d, 0x4d, 0x00, 0x2a] // "MM\0*"
const TIFF_LE = [0x49, 0x49, 0x2a, 0x00] // "II*\0"

const matchesAt = (bytes: Uint8Array, at: number, pattern: number[]) =>
  pattern.every((byte, i) => bytes[at + i] === byte)

/**
 * Returns the TIFF block of the Exif item of a HEIC, or null. Phones store
 * the item as "Exif\0\0" + the TIFF header. The TIFF magic immediately after
 * the marker prevents an accidental match in the pixel data.
 * ponytail: this is a marker scan, not a walk through the ISOBMFF boxes (the
 * server does the same). The function cuts the block at the APP1 limit. The
 * EXIF of a phone photo stays much smaller than this limit.
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
 * The converted pixels are already upright. An Orientation tag copied as is
 * rotates the photo a second time. To prevent this, the function sets the
 * Orientation tag of IFD0 back to 1 (normal).
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

/**
 * Returns the JPEG with the TIFF block inserted as an APP1 segment after SOI.
 */
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
