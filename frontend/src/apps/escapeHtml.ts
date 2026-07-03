// Shared HTML-escaping helper for the imperative apps. A single copy avoids one
// app's escaping silently diverging from the others (an XSS-regression risk).
// Escapes quotes too: apps interpolate this output into double-quoted HTML
// attributes (href, value, data-*), not just element content.
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
