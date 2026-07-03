// Shared vCard/contact helpers, so the contacts app, contact detail view and
// photo people-tagging can't drift on how a name is derived or cleaned.
import type { Entry } from "../types";

// A trimmed contact field with leading/trailing vCard `;` separators stripped.
export function contactField(entry: Entry, key: string): string {
  const val = (entry.data?.[key] as string) || "";
  return val.trim().replace(/^;+|;+$/g, "").trim();
}

// Strips surrounding quote characters (straight, curly, guillemets).
export function cleanName(raw: string): string {
  return raw.replace(/^["'«»“”‘’]+|["'«»“”‘’]+$/g, "").trim();
}

// Display name: the vCard display_name, else the first "—"-separated title
// segment, else "(unnamed)".
export function contactName(c: Entry): string {
  const name = contactField(c, "display_name") || c.title?.split(" — ")[0] || "";
  return cleanName(name) || "(unnamed)";
}

// Up to two uppercase initials from a name.
export function contactInitials(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() || "")
    .join("");
}
