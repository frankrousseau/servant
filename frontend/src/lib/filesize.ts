// Single byte formatter (bytes/KB/MB/GB) shared by photos, files, photo detail
// and the audit page, which previously each carried a copy that disagreed on
// KB precision. Caps at GB: disk sizes read better as 1843.2 GB than 1.8 TB.
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`
}
