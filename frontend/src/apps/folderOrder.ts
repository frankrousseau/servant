import { ref } from "vue";
import type { AppContext, Entry } from "./types";

// Persisted per-app folder ordering. Folders are derived strings (not
// entities), so the order lives in a single `folder_order` entry per app
// (title = app id, data.folders = ordered folder paths). Folders absent from
// the list sort alphabetically after the ordered ones. Ordering is only ever
// compared between siblings, so one flat list works for nested paths too.
export interface FolderOrder {
  load(): Promise<void>;
  compare(a: string, b: string): number;
  /** Re-rank one sibling group; other entries keep their relative order. */
  setGroup(groupSeq: string[]): void;
  /** Keep order entries in sync when a folder (and its children) is renamed. */
  rename(from: string, to: string): void;
}

export function createFolderOrder(ctx: AppContext, app: string): FolderOrder {
  let entry: Entry | null = null;
  const order = ref<string[]>([]);

  function persist() {
    const attrs = { data: { folders: order.value } };
    // ponytail: rapid first-time reorders could race and create two entries;
    // load() picks the first one, the duplicate is inert.
    const req = entry
      ? ctx.api.entries.update(entry.id, attrs)
      : ctx.api.entries
          .create({ kind: "folder_order", source: "manual", title: app, ...attrs })
          .then((e) => {
            entry = e;
          });
    void req.catch(() => {});
  }

  return {
    async load() {
      try {
        const found = await ctx.api.entries.list({ kind: "folder_order" });
        entry = found.find((e) => (e.title || "") === app) || null;
        order.value = (entry?.data.folders as string[]) || [];
      } catch {
        // ordering degrades to alphabetical
      }
    },
    compare(a, b) {
      const ia = order.value.indexOf(a);
      const ib = order.value.indexOf(b);
      if (ia !== -1 || ib !== -1) {
        if (ia === -1) return 1;
        if (ib === -1) return -1;
        return ia - ib;
      }
      return a.toLowerCase().localeCompare(b.toLowerCase());
    },
    setGroup(groupSeq) {
      const inGroup = new Set(groupSeq);
      order.value = [...order.value.filter((p) => !inGroup.has(p)), ...groupSeq];
      persist();
    },
    rename(from, to) {
      if (!order.value.length) return;
      const next = order.value.map((p) =>
        p === from || p.startsWith(from + "/") ? to + p.slice(from.length) : p,
      );
      if (next.some((p, i) => p !== order.value[i])) {
        order.value = next;
        persist();
      }
    },
  };
}
