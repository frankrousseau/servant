import MarkdownIt from "markdown-it";

const md = new MarkdownIt({ breaks: true, linkify: true });

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Canonical form for note slugs and wikilink matching — must mirror the
 * backend `Servant.Notes.canon/1` (trim, lower-case, collapse whitespace).
 */
export function canon(str: string): string {
  return str.trim().toLowerCase().replace(/\s+/g, " ");
}

/**
 * Renders markdown to HTML, then turns `[[wikilinks]]` into anchors (flagged
 * `--new` when the target note doesn't exist yet, à la Obsidian) and `#tags`
 * into pills. Post-processing the rendered HTML keeps wikilink/tag text as
 * literal brackets/hashes that markdown-it leaves untouched.
 */
export function renderMarkdown(
  body: string,
  resolved: (target: string) => boolean,
): string {
  let html = md.render(body || "");

  html = html.replace(/\[\[([^\][]+)\]\]/g, (_m, raw: string) => {
    const target = raw.trim();
    const cls = resolved(target) ? "nt-wikilink" : "nt-wikilink nt-wikilink--new";
    return `<a class="${cls}" data-target="${escapeHtml(target)}">${escapeHtml(target)}</a>`;
  });

  html = html.replace(
    /(^|[\s(>])#([\p{L}0-9_][\p{L}0-9_/-]*)/gu,
    (_m, pre: string, tag: string) =>
      `${pre}<span class="nt-tag">#${escapeHtml(tag)}</span>`,
  );

  return html;
}
