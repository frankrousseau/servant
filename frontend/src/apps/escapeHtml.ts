// Shared HTML-escaping helper for the imperative apps. A single copy avoids one
// app's escaping silently diverging from the others (an XSS-regression risk).
export function escapeHtml(s: string): string {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}
