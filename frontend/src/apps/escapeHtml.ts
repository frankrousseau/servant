// Shared helper that escapes HTML for the imperative apps. With a single copy,
// the escaping of one app cannot silently diverge from the others (a risk of
// XSS regression). Escapes quotes too: apps interpolate this output into
// double-quoted HTML attributes (href, value, data-*), not only into element
// content.
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
