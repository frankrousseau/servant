import type { AppModule, AppContext, Entry } from "../types";
import { escapeHtml } from "../escapeHtml";
import { renderMarkdown, canon } from "./render";

type Note = Entry;

function noteFolder(n: Note): string {
  return ((n.data.folder as string) || "").trim();
}

function noteBody(n: Note): string {
  return (n.data.body as string) || "";
}

function noteTags(n: Note): string[] {
  return (n.data.tags as string[]) || [];
}

// A contact or event entry reachable via an @[[mention]].
interface Mentionable {
  id: string;
  kind: "contact" | "event";
  name: string;
}

// vcard contact titles look like "Name — org — email"; prefer the clean
// display name — mirror backend mention_keys.
function mentionName(e: Entry): string {
  return ((e.data.display_name as string) || (e.title || "").split(" — ")[0] || "").trim();
}

function dedupeByName(list: Mentionable[]): Mentionable[] {
  const seen = new Set<string>();
  return list.filter((m) => {
    const k = canon(m.name);
    if (!m.name || seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

function fullPath(folder: string, title: string): string {
  return folder ? `${folder}/${title}` : title;
}

// A note is reachable as `[[title]]` or `[[folder/title]]` — mirror backend.
function noteKeys(n: Note): string[] {
  const title = n.title || "";
  return [canon(title), canon(fullPath(noteFolder(n), title))];
}

interface TreeNode {
  name: string;
  path: string;
  folders: Map<string, TreeNode>;
  notes: Note[];
}

function emptyNode(name: string, path: string): TreeNode {
  return { name, path, folders: new Map(), notes: [] };
}

// Set by mount() so unmount() can flush a pending debounced save. A single
// notes instance is mounted at a time.
let flushPendingSave: (() => void) | null = null;
// Detaches the delegated preview-click listener from the (persistent) mount
// element on unmount — the element is reused across app switches, so without
// this each Notes visit would leave another stale handler firing on it.
let detachClick: (() => void) | null = null;

// Viewport coordinates of the caret in a textarea, measured with a hidden
// mirror div that replicates the textarea's text layout up to the caret.
function caretViewportPosition(ta: HTMLTextAreaElement): { left: number; top: number; lineHeight: number } {
  const cs = getComputedStyle(ta);
  const mirror = document.createElement("div");
  for (const prop of [
    "fontFamily",
    "fontSize",
    "fontWeight",
    "letterSpacing",
    "lineHeight",
    "textTransform",
    "wordSpacing",
    "paddingTop",
    "paddingRight",
    "paddingBottom",
    "paddingLeft",
    "borderWidth",
    "boxSizing",
    "tabSize",
  ] as const) {
    mirror.style[prop as never] = cs[prop as never];
  }
  mirror.style.position = "absolute";
  mirror.style.visibility = "hidden";
  mirror.style.whiteSpace = "pre-wrap";
  mirror.style.wordWrap = "break-word";
  mirror.style.overflow = "hidden";
  mirror.style.width = `${ta.clientWidth}px`;

  mirror.textContent = ta.value.slice(0, ta.selectionStart);
  const marker = document.createElement("span");
  marker.textContent = "​";
  mirror.appendChild(marker);
  document.body.appendChild(mirror);

  const lineHeight = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
  const rect = ta.getBoundingClientRect();
  const left = rect.left + marker.offsetLeft - ta.scrollLeft;
  const top = rect.top + marker.offsetTop - ta.scrollTop;
  mirror.remove();
  return { left, top, lineHeight };
}

function buildTree(list: Note[]): TreeNode {
  const root = emptyNode("", "");
  for (const n of list) {
    let cur = root;
    const folder = noteFolder(n);
    if (folder) {
      let path = "";
      for (const seg of folder.split("/").map((s) => s.trim()).filter(Boolean)) {
        path = path ? `${path}/${seg}` : seg;
        if (!cur.folders.has(seg)) cur.folders.set(seg, emptyNode(seg, path));
        cur = cur.folders.get(seg)!;
      }
    }
    cur.notes.push(n);
  }
  return root;
}

const notesApp: AppModule = {
  mount(el: HTMLElement, ctx: AppContext) {
    let notes: Note[] = [];
    let mentionables: Mentionable[] = [];
    let selectedId: string | null = null;
    let backlinks: Note[] = [];
    let searchQuery = "";
    let viewMode: "split" | "edit" | "preview" = "split";
    const collapsed = new Set<string>();
    let saveTimer: ReturnType<typeof setTimeout> | undefined;
    let saveChain: Promise<void> = Promise.resolve();
    let saveState: "idle" | "saving" | "saved" | "error" = "idle";
    let saveError = "";

    // ----- API -----

    async function apiList(): Promise<Note[]> {
      const res = await ctx.api.fetch("/api/notes");
      return (await res.json()).data;
    }

    async function apiCreate(attrs: Record<string, unknown>): Promise<Note> {
      const res = await ctx.api.fetch("/api/notes", {
        method: "POST",
        body: JSON.stringify(attrs),
      });
      return (await res.json()).data;
    }

    async function apiUpdate(id: string, attrs: Record<string, unknown>): Promise<Note> {
      const res = await ctx.api.fetch(`/api/notes/${id}`, {
        method: "PUT",
        body: JSON.stringify(attrs),
      });
      return (await res.json()).data;
    }

    async function apiDelete(id: string): Promise<void> {
      await ctx.api.fetch(`/api/notes/${id}`, { method: "DELETE" });
    }

    async function apiBacklinks(id: string): Promise<Note[]> {
      const res = await ctx.api.fetch(`/api/notes/${id}/backlinks`);
      return (await res.json()).data;
    }

    // ----- helpers -----

    function selected(): Note | null {
      return notes.find((n) => n.id === selectedId) || null;
    }

    function keySet(): Set<string> {
      const s = new Set<string>();
      for (const n of notes) for (const k of noteKeys(n)) s.add(k);
      return s;
    }

    function resolveTarget(target: string): Note | null {
      const c = canon(target);
      return notes.find((n) => noteKeys(n).includes(c)) || null;
    }

    function resolveMention(target: string): Mentionable | null {
      const c = canon(target);
      return mentionables.find((m) => canon(m.name) === c) || null;
    }

    function filteredNotes(): Note[] {
      if (!searchQuery.trim()) return notes;
      const q = searchQuery.toLowerCase();
      return notes.filter((n) => {
        const hay = [
          n.title || "",
          noteFolder(n),
          noteBody(n),
          noteTags(n).join(" "),
        ]
          .join(" ")
          .toLowerCase();
        return hay.includes(q);
      });
    }

    function uniqueTitle(base: string): string {
      const existing = new Set(notes.map((n) => (n.title || "").toLowerCase()));
      if (!existing.has(base.toLowerCase())) return base;
      let i = 2;
      while (existing.has(`${base} ${i}`.toLowerCase())) i++;
      return `${base} ${i}`;
    }

    function sortNotes(list: Note[]): Note[] {
      return [...list].sort((a, b) =>
        (a.title || "").toLowerCase().localeCompare((b.title || "").toLowerCase()),
      );
    }

    // ----- sidebar -----

    function renderTreeNode(node: TreeNode, depth: number, searching: boolean): string {
      const folders = [...node.folders.values()].sort((a, b) =>
        a.name.toLowerCase().localeCompare(b.name.toLowerCase()),
      );
      let html = "";
      for (const f of folders) {
        const isCollapsed = !searching && collapsed.has(f.path);
        html +=
          `<div class="nt-folder" data-folder="${escapeHtml(f.path)}" style="padding-left:${depth * 12 + 8}px">` +
          `<span class="nt-folder-caret">${isCollapsed ? "▸" : "▾"}</span>` +
          `<span class="nt-folder-name">${escapeHtml(f.name)}</span>` +
          `</div>`;
        if (!isCollapsed) html += renderTreeNode(f, depth + 1, searching);
      }
      for (const n of sortNotes(node.notes)) {
        const active = n.id === selectedId ? " nt-note--active" : "";
        html +=
          `<div class="nt-note${active}" data-id="${n.id}" style="padding-left:${depth * 12 + 22}px">` +
          `<span class="nt-note-title">${escapeHtml(n.title || "Untitled")}</span>` +
          `</div>`;
      }
      return html;
    }

    function renderSidebar() {
      const sidebar = el.querySelector(".nt-sidebar");
      if (!sidebar) return;
      const searching = !!searchQuery.trim();
      const list = filteredNotes();
      const tree = buildTree(list);
      const treeHtml = renderTreeNode(tree, 0, searching);

      sidebar.innerHTML =
        `<div class="nt-side-head">` +
        `<input class="nt-search" type="text" placeholder="Search notes..." value="${escapeHtml(searchQuery)}" />` +
        `<button class="nt-new-btn" title="New note">+</button>` +
        `</div>` +
        `<div class="nt-tree">${treeHtml || '<p class="nt-empty">No notes yet.</p>'}</div>`;

      const search = sidebar.querySelector(".nt-search") as HTMLInputElement | null;
      search?.addEventListener("input", (e) => {
        searchQuery = (e.target as HTMLInputElement).value;
        renderSidebar();
        const again = el.querySelector(".nt-search") as HTMLInputElement | null;
        if (again) {
          again.focus();
          again.setSelectionRange(searchQuery.length, searchQuery.length);
        }
      });

      sidebar.querySelector(".nt-new-btn")?.addEventListener("click", () => {
        void createNote();
      });

      sidebar.querySelectorAll(".nt-folder").forEach((row) => {
        row.addEventListener("click", () => {
          const path = (row as HTMLElement).dataset.folder!;
          if (collapsed.has(path)) collapsed.delete(path);
          else collapsed.add(path);
          renderSidebar();
        });
      });

      sidebar.querySelectorAll(".nt-note").forEach((row) => {
        row.addEventListener("click", () => {
          void selectNote((row as HTMLElement).dataset.id!);
        });
      });
    }

    // ----- editor -----

    function renderMain() {
      const main = el.querySelector(".nt-main");
      if (!main) return;
      const note = selected();

      if (!note) {
        main.innerHTML = '<p class="nt-placeholder">Select or create a note to start writing.</p>';
        return;
      }

      const showEditor = viewMode !== "preview";
      const showPreview = viewMode !== "edit";

      main.innerHTML =
        `<div class="nt-toolbar">` +
        `<input class="nt-title" value="${escapeHtml(note.title || "")}" placeholder="Untitled" />` +
        `<input class="nt-folder-input" value="${escapeHtml(noteFolder(note))}" placeholder="Folder (e.g. Projects/Servant)" />` +
        `<span class="nt-save-status"></span>` +
        `<div class="nt-view-toggle">` +
        ["edit", "split", "preview"]
          .map(
            (m) =>
              `<button class="nt-vb${viewMode === m ? " nt-vb--active" : ""}" data-view="${m}">${m}</button>`,
          )
          .join("") +
        `</div>` +
        `<button class="nt-delete" title="Delete note">🗑</button>` +
        `</div>` +
        `<div class="nt-panes">` +
        (showEditor ? `<textarea class="nt-body" placeholder="Write markdown… use [[wikilinks]] and #tags">${escapeHtml(noteBody(note))}</textarea>` : "") +
        (showPreview ? `<div class="nt-preview"></div>` : "") +
        `</div>` +
        `<div class="nt-backlinks"></div>`;

      const titleEl = main.querySelector(".nt-title") as HTMLInputElement;
      const folderEl = main.querySelector(".nt-folder-input") as HTMLInputElement;
      const bodyEl = main.querySelector(".nt-body") as HTMLTextAreaElement | null;

      titleEl?.addEventListener("input", scheduleSave);
      folderEl?.addEventListener("input", scheduleSave);
      bodyEl?.addEventListener("input", () => {
        scheduleSave();
        updatePreview();
        updateAutocomplete(bodyEl);
      });
      bodyEl?.addEventListener("keydown", (e) => handleAutocompleteKey(e, bodyEl));
      bodyEl?.addEventListener("blur", () => setTimeout(hideAutocomplete, 150));

      main.querySelectorAll(".nt-vb").forEach((b) =>
        b.addEventListener("click", () => {
          viewMode = (b as HTMLElement).dataset.view as typeof viewMode;
          renderMain();
        }),
      );

      main.querySelector(".nt-delete")?.addEventListener("click", () => {
        void deleteNote(note);
      });

      updatePreview();
      renderBacklinks();
      renderSaveStatus();
    }

    function renderSaveStatus() {
      const s = el.querySelector(".nt-save-status") as HTMLElement | null;
      if (!s) return;
      const labels = { idle: "", saving: "Saving…", saved: "Saved", error: "" };
      s.textContent = saveState === "error" ? saveError || "Save failed" : labels[saveState];
      s.classList.toggle("nt-save-status--error", saveState === "error");
      s.title = saveState === "error" ? saveError : "";
    }

    function currentBody(): string {
      const bodyEl = el.querySelector(".nt-body") as HTMLTextAreaElement | null;
      if (bodyEl) return bodyEl.value;
      return noteBody(selected() || ({ data: {} } as Note));
    }

    function updatePreview() {
      const preview = el.querySelector(".nt-preview");
      if (!preview) return;
      const keys = keySet();
      preview.innerHTML = renderMarkdown(
        currentBody(),
        (t) => keys.has(canon(t)),
        (t) => resolveMention(t)?.kind ?? null,
      );
    }

    function renderBacklinks() {
      const box = el.querySelector(".nt-backlinks");
      if (!box) return;
      if (!backlinks.length) {
        box.innerHTML = "";
        return;
      }
      box.innerHTML =
        `<div class="nt-bl-title">Linked from</div>` +
        backlinks
          .map((n) => `<a class="nt-bl-item" data-id="${n.id}">${escapeHtml(n.title || "Untitled")}</a>`)
          .join("");
      box.querySelectorAll(".nt-bl-item").forEach((a) =>
        a.addEventListener("click", () => {
          void selectNote((a as HTMLElement).dataset.id!);
        }),
      );
    }

    // ----- wikilink / mention autocomplete -----

    interface AcItem {
      label: string;
      icon: string;
      // Full replacement for the `acReplaceLen` chars before the caret.
      text: string;
    }

    let acItems: AcItem[] = [];
    let acIndex = 0;
    let acReplaceLen = 0;

    function hideAutocomplete() {
      // The popup lives in document.body (not in `el`), so search the document.
      document.querySelectorAll(".nt-ac").forEach((p) => p.remove());
      acItems = [];
    }

    function highlightAcItem() {
      document.querySelectorAll(".nt-ac-item").forEach((item, i) => {
        item.classList.toggle("nt-ac-item--active", i === acIndex);
        if (i === acIndex) item.scrollIntoView({ block: "nearest" });
      });
    }

    function handleAutocompleteKey(e: KeyboardEvent, ta: HTMLTextAreaElement) {
      if (!acItems.length || !document.querySelector(".nt-ac")) return;
      if (e.key === "Escape") {
        hideAutocomplete();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        acIndex = (acIndex + 1) % acItems.length;
        highlightAcItem();
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        acIndex = (acIndex - 1 + acItems.length) % acItems.length;
        highlightAcItem();
      } else if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault();
        applyCompletion(ta, acItems[acIndex]);
      }
    }

    function mentionItems(query: string, close: boolean): AcItem[] {
      const q = query.toLowerCase();
      return mentionables
        .filter((m) => m.name.toLowerCase().includes(q))
        .slice(0, 8)
        .map((m) => ({
          label: m.name,
          icon: m.kind === "event" ? "📅" : "👤",
          text: close ? `${m.name}]]` : `@[[${m.name}]]`,
        }));
    }

    function updateAutocomplete(ta: HTMLTextAreaElement) {
      const before = ta.value.slice(0, ta.selectionStart);
      hideAutocomplete();

      // Three triggers: `[[` completes notes, `@[[` and bare `@` complete
      // contact/event mentions (the lookbehind keeps them disjoint).
      const wiki = before.match(/(?<!@)\[\[([^\][]*)$/);
      const openMention = wiki ? null : before.match(/@\[\[([^\][]*)$/);
      const bareMention =
        wiki || openMention ? null : before.match(/(?<![\w@])@([\p{L}\p{N} '’_-]*)$/u);

      if (wiki) {
        const q = wiki[1].toLowerCase();
        acReplaceLen = wiki[1].length;
        acItems = sortNotes(
          notes.filter((n) => (n.title || "").toLowerCase().includes(q)),
        )
          .slice(0, 8)
          .map((n) => ({ label: n.title || "", icon: "", text: `${n.title || ""}]]` }));
      } else if (openMention) {
        acReplaceLen = openMention[1].length;
        acItems = mentionItems(openMention[1], true);
      } else if (bareMention) {
        acReplaceLen = bareMention[1].length + 1;
        acItems = mentionItems(bareMention[1], false);
      } else {
        return;
      }
      if (!acItems.length) return;
      acIndex = 0;

      const pop = document.createElement("div");
      pop.className = "nt-ac";
      pop.innerHTML = acItems
        .map(
          (item, i) =>
            `<div class="nt-ac-item${i === 0 ? " nt-ac-item--active" : ""}" data-index="${i}">${item.icon ? `${item.icon} ` : ""}${escapeHtml(item.label)}</div>`,
        )
        .join("");

      // Anchor at the caret, clamped to the viewport; flip above the line if
      // there is no room below.
      const caret = caretViewportPosition(ta);
      pop.style.visibility = "hidden";
      document.body.appendChild(pop);
      const popW = pop.offsetWidth;
      const popH = pop.offsetHeight;
      let left = Math.min(caret.left, window.innerWidth - popW - 8);
      let top = caret.top + caret.lineHeight;
      if (top + popH > window.innerHeight - 8) top = caret.top - popH - 4;
      pop.style.left = `${Math.max(8, left)}px`;
      pop.style.top = `${Math.max(8, top)}px`;
      pop.style.visibility = "";

      pop.querySelectorAll(".nt-ac-item").forEach((item) =>
        item.addEventListener("mousedown", (e) => {
          e.preventDefault();
          applyCompletion(ta, acItems[Number((item as HTMLElement).dataset.index)]);
        }),
      );
    }

    function applyCompletion(ta: HTMLTextAreaElement, item: AcItem) {
      const pos = ta.selectionStart;
      const before = ta.value.slice(0, pos - acReplaceLen);
      const after = ta.value.slice(pos);
      ta.value = before + item.text + after;
      const newPos = before.length + item.text.length;
      ta.setSelectionRange(newPos, newPos);
      hideAutocomplete();
      ta.focus();
      scheduleSave();
      updatePreview();
    }

    // ----- mutations -----

    function scheduleSave() {
      if (saveTimer) clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        saveTimer = undefined;
        void enqueueSave();
      }, 600);
    }

    // Serialize saves so a slow response can't overwrite a later one.
    function enqueueSave(): Promise<void> {
      saveChain = saveChain.then(() => save());
      return saveChain;
    }

    // Runs the debounced save now (if one is pending). Used when leaving the
    // note or unmounting the app, so pending edits aren't lost.
    function flushSave(): Promise<void> {
      if (!saveTimer) return saveChain;
      clearTimeout(saveTimer);
      saveTimer = undefined;
      return enqueueSave();
    }

    async function save() {
      const note = selected();
      if (!note) return;
      const titleEl = el.querySelector(".nt-title") as HTMLInputElement | null;
      const folderEl = el.querySelector(".nt-folder-input") as HTMLInputElement | null;
      const bodyEl = el.querySelector(".nt-body") as HTMLTextAreaElement | null;

      const attrs = {
        title: (titleEl?.value ?? note.title ?? "").trim(),
        folder: (folderEl?.value ?? noteFolder(note)).trim(),
        body: bodyEl?.value ?? noteBody(note),
      };
      if (!attrs.title) return;

      const renamed =
        attrs.title !== (note.title || "") || attrs.folder !== noteFolder(note);

      saveState = "saving";
      renderSaveStatus();
      try {
        const updated = await apiUpdate(note.id, attrs);
        if (renamed) {
          // A rename rewrites [[wikilinks]] in referencing notes server-side;
          // reload so we don't hold (and later save back) stale bodies.
          notes = await apiList();
        } else {
          notes = notes.map((n) => (n.id === updated.id ? updated : n));
        }
        saveState = "saved";
        saveError = "";
        renderSidebar();
        updatePreview();
      } catch (e) {
        saveState = "error";
        saveError = e instanceof Error ? e.message : "Save failed";
      }
      renderSaveStatus();
    }

    async function createNote(folder = "") {
      try {
        const created = await apiCreate({ title: uniqueTitle("Untitled"), folder, body: "" });
        notes.push(created);
        selectedId = created.id;
        backlinks = [];
        saveState = "idle";
        saveError = "";
        viewMode = "split";
        renderSidebar();
        renderMain();
        const titleEl = el.querySelector(".nt-title") as HTMLInputElement | null;
        titleEl?.focus();
        titleEl?.select();
      } catch {
        // ignore
      }
    }

    async function selectNote(id: string) {
      await flushSave();
      saveState = "idle";
      saveError = "";
      selectedId = id;
      backlinks = [];
      hideAutocomplete();
      renderSidebar();
      renderMain();
      try {
        backlinks = await apiBacklinks(id);
        if (selectedId === id) renderBacklinks();
      } catch {
        // ignore
      }
    }

    async function deleteNote(note: Note) {
      const ok = await ctx.confirm.ask({
        title: "Delete note",
        message: `Delete "${note.title || "Untitled"}"? This cannot be undone.`,
        confirmLabel: "Delete",
        danger: true,
      });
      if (!ok) return;
      try {
        await apiDelete(note.id);
        notes = notes.filter((n) => n.id !== note.id);
        if (selectedId === note.id) {
          selectedId = null;
          backlinks = [];
        }
        renderSidebar();
        renderMain();
      } catch {
        // ignore
      }
    }

    // Delegated wikilink and mention clicks in the preview.
    const onPreviewClick = (e: MouseEvent) => {
      const mention = (e.target as HTMLElement).closest(".nt-mention") as HTMLElement | null;
      if (mention) {
        e.preventDefault();
        const item = resolveMention(mention.dataset.target || "");
        if (item?.kind === "contact") ctx.navigate(`/contacts/${item.id}`);
        else if (item?.kind === "event") ctx.navigate("/apps/calendar");
        return;
      }
      const link = (e.target as HTMLElement).closest(".nt-wikilink") as HTMLElement | null;
      if (!link) return;
      e.preventDefault();
      const target = link.dataset.target || "";
      const existing = resolveTarget(target);
      if (existing) void selectNote(existing.id);
      else void createNamedNote(target);
    };
    el.addEventListener("click", onPreviewClick);
    detachClick = () => el.removeEventListener("click", onPreviewClick);

    async function createNamedNote(title: string) {
      try {
        const created = await apiCreate({ title, folder: "", body: "" });
        notes.push(created);
        await selectNote(created.id);
      } catch {
        // ignore
      }
    }

    // ----- styles -----

    const style = document.createElement("style");
    style.dataset.app = "notes";
    style.textContent = [
      ".nt-layout { display: flex; height: calc(100vh - 4rem); }",
      ".nt-sidebar { width: 280px; flex-shrink: 0; display: flex; flex-direction: column; border-right: 1px solid var(--border); }",
      ".nt-side-head { display: flex; gap: 0.5rem; padding: 0.75rem; border-bottom: 1px solid var(--border); }",
      ".nt-search { flex: 1; }",
      ".nt-new-btn { width: 32px; flex-shrink: 0; border: 1px solid var(--border); background: transparent; color: var(--text-muted); border-radius: 8px; font-size: 1.1rem; cursor: pointer; }",
      ".nt-new-btn:hover { border-color: var(--primary); color: var(--primary); }",
      ".nt-tree { flex: 1; overflow-y: auto; padding: 0.375rem 0.25rem; }",
      ".nt-folder { display: flex; align-items: center; gap: 0.35rem; padding: 0.3rem 0.4rem; border-radius: 6px; cursor: pointer; color: var(--text-muted); font-size: 0.9rem; }",
      ".nt-folder:hover { background: var(--bg-hover); }",
      ".nt-folder-caret { width: 0.9em; flex-shrink: 0; }",
      ".nt-note { padding: 0.3rem 0.4rem; border-radius: 6px; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 0.9rem; }",
      ".nt-note:hover { background: var(--bg-hover); }",
      ".nt-note--active { background: var(--bg-hover); color: var(--primary); }",
      ".nt-empty, .nt-placeholder { color: var(--text-muted); text-align: center; padding: 2.5rem 1rem; }",
      ".nt-main { flex: 1; display: flex; flex-direction: column; min-width: 0; }",
      ".nt-toolbar { display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.75rem; border-bottom: 1px solid var(--border); }",
      ".nt-title { font-weight: 600; flex: 1; min-width: 0; }",
      ".nt-folder-input { width: 220px; flex-shrink: 0; color: var(--text); display: block; }",
      ".nt-save-status { flex-shrink: 0; font-size: 0.75rem; color: var(--text-muted); max-width: 240px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
      ".nt-save-status--error { color: var(--danger); }",
      ".nt-view-toggle { display: flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }",
      ".nt-vb { background: transparent; border: none; color: var(--text-muted); padding: 0.35rem 0.6rem; font-size: 0.8rem; cursor: pointer; text-transform: capitalize; }",
      ".nt-vb:hover { background: var(--bg-hover); }",
      ".nt-vb--active { background: var(--primary); color: #fff; }",
      ".nt-delete { background: transparent; border: 1px solid var(--border); color: var(--text-muted); border-radius: 8px; padding: 0.35rem 0.5rem; cursor: pointer; }",
      ".nt-delete:hover { border-color: var(--danger); color: var(--danger); }",
      ".nt-panes { flex: 1; display: flex; min-height: 0; }",
      ".nt-body { flex: 1; border: none; border-radius: 0; resize: none; padding: 1rem 1.25rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9rem; line-height: 1.6; background: var(--bg); color: var(--text); }",
      ".nt-body:focus { outline: none; }",
      ".nt-panes:has(.nt-body):has(.nt-preview) .nt-body { border-right: 1px solid var(--border); }",
      ".nt-preview { flex: 1; overflow-y: auto; padding: 1rem 1.25rem; line-height: 1.65; }",
      ".nt-preview h1, .nt-preview h2, .nt-preview h3 { margin: 0.8em 0 0.4em; }",
      ".nt-preview p { margin: 0.5em 0; }",
      ".nt-preview code { background: var(--bg-surface); padding: 0.1em 0.35em; border-radius: 4px; font-size: 0.85em; }",
      ".nt-preview pre { background: var(--bg-surface); padding: 0.75rem; border-radius: 8px; overflow-x: auto; }",
      ".nt-preview pre code { background: none; padding: 0; }",
      ".nt-preview a { color: var(--primary); }",
      ".nt-preview ul, .nt-preview ol { padding-left: 1.4em; }",
      ".nt-preview blockquote { border-left: 3px solid var(--border); margin: 0.5em 0; padding-left: 0.8em; color: var(--text-muted); }",
      ".nt-wikilink { color: var(--primary); text-decoration: none; border-bottom: 1px solid transparent; cursor: pointer; }",
      ".nt-wikilink:hover { border-bottom-color: var(--primary); }",
      ".nt-wikilink--new { color: var(--danger); }",
      ".nt-mention { display: inline-block; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 999px; padding: 0 0.5em; font-size: 0.85em; color: var(--text); cursor: pointer; text-decoration: none; }",
      ".nt-mention:hover { border-color: var(--primary); color: var(--primary); }",
      ".nt-mention--unknown { opacity: 0.6; border-style: dashed; cursor: default; }",
      ".nt-tag { display: inline-block; background: rgba(108, 140, 255, 0.15); color: var(--primary); border-radius: 6px; padding: 0 0.4em; font-size: 0.85em; }",
      ".nt-backlinks { border-top: 1px solid var(--border); padding: 0.5rem 1.25rem; max-height: 30%; overflow-y: auto; }",
      ".nt-backlinks:empty { display: none; }",
      ".nt-bl-title { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; color: var(--text-muted); margin-bottom: 0.4rem; }",
      ".nt-bl-item { display: inline-block; margin: 0 0.5rem 0.3rem 0; color: var(--primary); cursor: pointer; font-size: 0.9rem; }",
      ".nt-bl-item:hover { text-decoration: underline; }",
      ".nt-ac { position: fixed; z-index: 10000; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 8px; padding: 0.25rem; min-width: 180px; max-height: 240px; overflow-y: auto; box-shadow: 0 8px 24px rgba(0,0,0,0.4); }",
      ".nt-ac-item { padding: 0.35rem 0.6rem; border-radius: 6px; cursor: pointer; font-size: 0.9rem; }",
      ".nt-ac-item:hover, .nt-ac-item--active { background: var(--bg-hover); }",
      ".nt-body, .nt-title, .nt-folder-input, .nt-search { color-scheme: dark; }",
    ].join("\n");
    document.head.appendChild(style);

    // ----- bootstrap -----

    flushPendingSave = () => void flushSave();

    el.innerHTML =
      '<div class="nt-layout"><div class="nt-sidebar"></div><div class="nt-main"></div></div>';
    (el.querySelector(".nt-main") as HTMLElement).innerHTML =
      '<p class="nt-placeholder">Loading notes…</p>';

    apiList()
      .then((list) => {
        notes = list;
        renderSidebar();
        renderMain();
      })
      .catch(() => {
        const main = el.querySelector(".nt-main");
        if (main) main.innerHTML = '<p class="nt-placeholder">Failed to load notes.</p>';
      });

    // Contacts and events feed @[[mention]] autocomplete and chip resolution;
    // the app degrades gracefully without them.
    Promise.all([
      ctx.api.entries.list({ kind: "contact" }),
      ctx.api.entries.list({ kind: "event" }),
    ])
      .then(([contacts, events]) => {
        const contactItems = dedupeByName(
          contacts
            .map((c) => ({ id: c.id, kind: "contact" as const, name: mentionName(c) }))
            .sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase())),
        );
        const eventItems = dedupeByName(
          events
            .slice()
            // Recent first, so recurring event titles resolve to the latest one.
            .sort((a, b) => (b.occurred_at || "").localeCompare(a.occurred_at || ""))
            .map((e) => ({ id: e.id, kind: "event" as const, name: (e.title || "").trim() })),
        );
        mentionables = [...contactItems, ...eventItems];
        updatePreview();
      })
      .catch(() => {
        // mention chips render as unresolved without this data
      });
  },

  unmount(el) {
    // Flush before clearing the DOM: save() captures input values synchronously.
    flushPendingSave?.();
    flushPendingSave = null;
    detachClick?.();
    detachClick = null;
    el.innerHTML = "";
    document.querySelectorAll(".nt-ac").forEach((p) => p.remove());
    document.querySelector('style[data-app="notes"]')?.remove();
  },
};

export default notesApp;
