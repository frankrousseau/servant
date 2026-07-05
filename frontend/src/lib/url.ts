// Shared URL-safety helper. Vue does NOT sanitize `javascript:`/`data:` URIs in
// `:href` bindings, so any user-controlled URL (e.g. a vCard `url` field) must be
// filtered before it reaches an href, or it becomes a stored-XSS vector.
export function safeUrl(url: string): string | null {
  if (!url) return null
  try {
    const scheme = new URL(url, window.location.origin).protocol
    return ['http:', 'https:', 'mailto:', 'tel:'].includes(scheme) ? url : null
  } catch {
    return null
  }
}
