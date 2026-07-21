/// <reference lib="webworker" />
import { heicTo } from 'heic-to/next'

// Decoding a 48MP HEIC blocks for seconds; done inline a 500-file batch
// freezes the tab. heic-to/next is the OffscreenCanvas build made for
// workers.
self.onmessage = async (e: MessageEvent<{ file: File }>) => {
  try {
    const blob = await heicTo({
      blob: e.data.file,
      type: 'image/jpeg',
      quality: 0.9
    })
    self.postMessage({ blob })
  } catch (error) {
    self.postMessage({ error: String(error) })
  }
}
