import type { AppContext } from '../types'
import { createUploadQueue } from '../../lib/uploadQueue'

export type { UploadProgress } from '../../lib/uploadQueue'

// Files upload pipeline on the shared module-level queue: uploads survive
// navigating to another app. The target folder is captured per file at
// enqueue time.

type FilesApi = AppContext['api']

interface FileUpload {
  file: File
  parentId: string | null
  api: FilesApi
}

const queue = createUploadQueue<FileUpload>({
  itemName: item => item.file.name,
  itemSize: item => item.file.size,
  async process({ file, parentId, api }, tools) {
    const result = await api.upload(file, 'files', tools.onBytesPct)
    return api.entries.create({
      kind: 'file',
      source: 'files_app',
      title: file.name,
      data: {
        filename: file.name,
        size: result.size,
        mime_type: result.mime_type,
        path: result.path,
        parent_id: parentId,
        is_folder: false
      }
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
  api: FilesApi,
  parentId: string | null
) {
  queue.enqueue(files.map(file => ({ file, parentId, api })))
}
