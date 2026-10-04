// The single byte formatter (bytes/KB/MB/GB). These pages share it:
// - photos
// - files
// - photo detail
// - the audit page
// Before, each of them had a copy, and the copies did not agree on the KB
// precision. The largest unit is GB: a disk size is easier to read as
// 1843.2 GB than as 1.8 TB.
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`
}
