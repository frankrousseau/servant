// A shared helper for URL safety. Vue does NOT sanitize `javascript:` and
// `data:` URIs in `:href` bindings. Filter each user-controlled URL (for
// example a vCard `url` field) before it reaches an href. If you do not, it
// becomes a stored-XSS vector.
export function safeUrl(url: string): string | null {
  if (!url) return null
  try {
    const scheme = new URL(url, window.location.origin).protocol
    return ['http:', 'https:', 'mailto:', 'tel:'].includes(scheme) ? url : null
  } catch {
    return null
  }
}
