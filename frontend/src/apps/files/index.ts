import type { AppModule, Entry } from "../types";

function escapeHtml(s: string): string {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function getField(e: Entry, k: string): unknown {
  return e.data[k];
}

const FILE_ICONS: Record<string, string> = {
  folder: "📁",
  pdf: "📄",
  image: "🖼️",
  text: "📝",
  zip: "📦",
  default: "📎",
};

function fileIcon(entry: Entry): string {
  if (getField(entry, "is_folder")) return FILE_ICONS.folder;
  const mime = (getField(entry, "mime_type") as string) || "";
  if (mime.startsWith("image/")) return FILE_ICONS.image;
  if (mime === "application/pdf") return FILE_ICONS.pdf;
  if (mime.startsWith("text/")) return FILE_ICONS.text;
  if (mime.includes("zip")) return FILE_ICONS.zip;
  return FILE_ICONS.default;
}

const filesApp: AppModule = {
  mount(el, ctx) {
    let allFiles: Entry[] = [];
    let currentFolder: string | null = null; // null = root
    let selectedId: string | null = null;
    let folderPath: { id: string | null; name: string }[] = [{ id: null, name: "Files" }];

    function currentItems(): Entry[] {
      return allFiles
        .filter((f) => (getField(f, "parent_id") || null) === currentFolder)
        .sort((a, b) => {
          // Folders first, then alphabetical
          const aFolder = getField(a, "is_folder") ? 0 : 1;
          const bFolder = getField(b, "is_folder") ? 0 : 1;
          if (aFolder !== bFolder) return aFolder - bFolder;
          const aName = ((getField(a, "filename") as string) || "").toLowerCase();
          const bName = ((getField(b, "filename") as string) || "").toLowerCase();
          return aName.localeCompare(bName);
        });
    }

    function render() {
      const items = currentItems();
      const sel = selectedId ? allFiles.find((f) => f.id === selectedId) : null;

      const breadcrumbs = folderPath
        .map(
          (p, i) =>
            `<span class="fs-crumb" data-idx="${i}">${escapeHtml(p.name)}</span>`,
        )
        .join('<span class="fs-crumb-sep">/</span>');

      el.innerHTML = `
        <div class="fs-layout">
          <div class="fs-main">
            <div class="fs-toolbar">
              <div class="fs-breadcrumbs">${breadcrumbs}</div>
              <div class="fs-actions">
                <button class="fs-btn" id="fs-new-folder">+ Folder</button>
                <label class="fs-btn fs-upload-label">
                  + Upload
                  <input type="file" id="fs-upload" multiple hidden />
                </label>
              </div>
            </div>
            <div class="fs-grid">
              ${items
                .map(
                  (f) => `
                <div class="fs-item ${f.id === selectedId ? "fs-item--active" : ""}" data-id="${f.id}" data-folder="${getField(f, "is_folder") ? "1" : "0"}">
                  <span class="fs-icon">${fileIcon(f)}</span>
                  <span class="fs-name">${escapeHtml((getField(f, "filename") as string) || "(unnamed)")}</span>
                  ${!getField(f, "is_folder") ? `<span class="fs-size">${formatSize((getField(f, "size") as number) || 0)}</span>` : ""}
                </div>`,
                )
                .join("")}
              ${items.length === 0 ? '<p class="fs-empty">This folder is empty</p>' : ""}
            </div>
          </div>
          <div class="fs-detail-col">
            ${sel ? renderDetail(sel) : '<p class="fs-placeholder">Select a file to view details</p>'}
          </div>
        </div>
      `;

      // Bind breadcrumbs
      el.querySelectorAll(".fs-crumb").forEach((crumb) => {
        crumb.addEventListener("click", () => {
          const idx = parseInt((crumb as HTMLElement).dataset.idx || "0");
          folderPath = folderPath.slice(0, idx + 1);
          currentFolder = folderPath[folderPath.length - 1].id;
          selectedId = null;
          render();
        });
      });

      // Bind items
      el.querySelectorAll(".fs-item").forEach((item) => {
        const htmlItem = item as HTMLElement;
        item.addEventListener("click", () => {
          selectedId = htmlItem.dataset.id || null;
          render();
        });
        item.addEventListener("dblclick", () => {
          if (htmlItem.dataset.folder === "1") {
            const entry = allFiles.find((f) => f.id === htmlItem.dataset.id);
            if (entry) {
              currentFolder = entry.id;
              folderPath.push({ id: entry.id, name: (getField(entry, "filename") as string) || "Folder" });
              selectedId = null;
              render();
            }
          }
        });
      });

      // New folder
      el.querySelector("#fs-new-folder")?.addEventListener("click", async () => {
        const name = prompt("Folder name:");
        if (!name) return;
        await ctx.api.entries.create({
          kind: "file",
          source: "files_app",
          title: name,
          data: { filename: name, is_folder: true, parent_id: currentFolder },
        });
        await reload();
      });

      // Shared upload logic
      async function uploadFiles(files: File[]) {
        for (const file of files) {
          const result = await ctx.api.upload(file, "files")
          await ctx.api.entries.create({
            kind: "file",
            source: "files_app",
            title: file.name,
            data: {
              filename: file.name,
              size: result.size,
              mime_type: result.mime_type,
              path: result.path,
              parent_id: currentFolder,
              is_folder: false,
            },
          });
        }
        await reload();
      }

      // File input upload
      el.querySelector("#fs-upload")?.addEventListener("change", (e) => {
        const input = e.target as HTMLInputElement;
        if (input.files?.length) uploadFiles(Array.from(input.files));
      });

      // Drag & drop
      const grid = el.querySelector(".fs-grid");
      if (grid) {
        grid.addEventListener("dragover", (e) => {
          e.preventDefault();
          grid.classList.add("fs-dragover");
        });
        grid.addEventListener("dragleave", () => {
          grid.classList.remove("fs-dragover");
        });
        grid.addEventListener("drop", (e) => {
          e.preventDefault();
          grid.classList.remove("fs-dragover");
          const dt = (e as DragEvent).dataTransfer;
          if (dt?.files.length) uploadFiles(Array.from(dt.files));
        });
      }
    }

    function renderDetail(f: Entry): string {
      const isFolder = getField(f, "is_folder");
      const filename = (getField(f, "filename") as string) || "(unnamed)";
      const path = getField(f, "path") as string;

      return `
        <div class="fs-detail">
          <span class="fs-detail-icon">${fileIcon(f)}</span>
          <h3 class="fs-detail-name">${escapeHtml(filename)}</h3>
          ${!isFolder ? `
            <div class="fs-detail-meta">
              <div class="fs-meta-row">
                <span class="fs-meta-label">Size</span>
                <span>${formatSize((getField(f, "size") as number) || 0)}</span>
              </div>
              <div class="fs-meta-row">
                <span class="fs-meta-label">Type</span>
                <span>${escapeHtml((getField(f, "mime_type") as string) || "Unknown")}</span>
              </div>
              <div class="fs-meta-row">
                <span class="fs-meta-label">Added</span>
                <span>${new Date(f.inserted_at).toLocaleDateString()}</span>
              </div>
              ${path ? `<a class="fs-download" href="${escapeHtml(path)}" target="_blank" download>Download</a>` : ""}
            </div>
          ` : `
            <div class="fs-detail-meta">
              <div class="fs-meta-row">
                <span class="fs-meta-label">Type</span>
                <span>Folder</span>
              </div>
              <div class="fs-meta-row">
                <span class="fs-meta-label">Created</span>
                <span>${new Date(f.inserted_at).toLocaleDateString()}</span>
              </div>
            </div>
          `}
          <button class="fs-delete" data-id="${f.id}">Delete</button>
        </div>
      `;
    }

    async function reload() {
      allFiles = await ctx.api.entries.list({ kind: "file" });
      render();
    }

    // Delegate delete clicks
    el.addEventListener("click", async (e) => {
      const btn = (e.target as HTMLElement).closest(".fs-delete") as HTMLElement | null;
      if (!btn) return;
      const id = btn.dataset.id;
      if (!id) return;
      const ok = await ctx.confirm.ask({ message: "Delete this item?" });
      if (!ok) return;
      await ctx.api.entries.delete(id);
      selectedId = null;
      await reload();
    });

    // Inject styles
    const style = document.createElement("style");
    style.dataset.app = "files";
    style.textContent = `
      .fs-layout {
        display: flex;
        height: calc(100vh - 4rem);
      }
      .fs-main {
        flex: 1;
        display: flex;
        flex-direction: column;
        min-width: 0;
      }
      .fs-detail-col {
        width: 300px;
        flex-shrink: 0;
        border-left: 1px solid var(--border);
        overflow-y: auto;
        padding: 1.5rem;
      }
      .fs-toolbar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 0.75rem 1rem;
        border-bottom: 1px solid var(--border);
        gap: 0.5rem;
      }
      .fs-breadcrumbs {
        display: flex;
        align-items: center;
        gap: 0.25rem;
        font-size: 0.9rem;
        min-width: 0;
        overflow: hidden;
      }
      .fs-crumb {
        color: var(--text-muted);
        cursor: pointer;
        white-space: nowrap;
      }
      .fs-crumb:hover { color: var(--text); }
      .fs-crumb:last-child { color: var(--text); font-weight: 500; }
      .fs-crumb-sep { color: var(--text-muted); }
      .fs-actions {
        display: flex;
        gap: 0.375rem;
        flex-shrink: 0;
      }
      .fs-btn {
        background: transparent;
        border: 1px solid var(--border);
        color: var(--text-muted);
        padding: 0.4rem 0.75rem;
        border-radius: 8px;
        cursor: pointer;
        font-size: 0.85rem;
        white-space: nowrap;
      }
      .fs-btn:hover { border-color: var(--primary); color: var(--text); }
      .fs-upload-label { display: inline-flex; align-items: center; }
      .fs-grid {
        flex: 1;
        overflow-y: auto;
        padding: 0.75rem;
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
        gap: 0.5rem;
        align-content: start;
      }
      .fs-item {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.35rem;
        padding: 1rem 0.5rem;
        border-radius: 10px;
        cursor: pointer;
        transition: background 0.1s;
        text-align: center;
      }
      .fs-item:hover { background: var(--bg-hover); }
      .fs-item--active { background: var(--bg-hover); outline: 1px solid var(--primary); }
      .fs-icon { font-size: 2rem; line-height: 1; }
      .fs-name {
        font-size: 0.85rem;
        word-break: break-word;
        max-width: 100%;
      }
      .fs-size {
        font-size: 0.75rem;
        color: var(--text-muted);
      }
      .fs-grid.fs-dragover {
        outline: 2px dashed var(--primary);
        outline-offset: -4px;
        background: rgba(108, 140, 255, 0.05);
      }
      .fs-empty {
        color: var(--text-muted);
        text-align: center;
        padding: 3rem;
        grid-column: 1 / -1;
      }
      .fs-placeholder {
        color: var(--text-muted);
        text-align: center;
        padding: 3rem 1rem;
      }
      .fs-detail {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.5rem;
      }
      .fs-detail-icon { font-size: 3rem; }
      .fs-detail-name {
        margin: 0;
        font-size: 1rem;
        text-align: center;
        word-break: break-word;
      }
      .fs-detail-meta {
        width: 100%;
        margin-top: 0.75rem;
      }
      .fs-meta-row {
        display: flex;
        justify-content: space-between;
        padding: 0.4rem 0;
        font-size: 0.85rem;
        border-bottom: 1px solid var(--border);
      }
      .fs-meta-label { color: var(--text-muted); }
      .fs-download {
        display: block;
        text-align: center;
        margin-top: 0.75rem;
        color: var(--primary);
        text-decoration: none;
        font-size: 0.9rem;
      }
      .fs-download:hover { text-decoration: underline; }
      .fs-delete {
        margin-top: 1rem;
        background: transparent;
        border: 1px solid var(--border);
        color: var(--text-muted);
        padding: 0.4rem 1rem;
        border-radius: 8px;
        cursor: pointer;
        font-size: 0.85rem;
        width: 100%;
      }
      .fs-delete:hover { border-color: var(--danger); color: var(--danger); }
    `;
    document.head.appendChild(style);

    el.innerHTML = '<p style="color: var(--text-muted); padding: 2rem;">Loading files...</p>';
    reload();
  },

  unmount(el) {
    el.innerHTML = "";
    document.querySelector('style[data-app="files"]')?.remove();
  },
};

export default filesApp;
