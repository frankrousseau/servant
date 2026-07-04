<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from "vue";
import {
  Folder,
  File,
  FileText,
  FileArchive,
  Image as ImageIcon,
  Video,
} from "lucide-vue-next";
import type { AppContext, Entry } from "../types";
import { formatFileSize } from "../../types";
import { formatDate } from "../../lib/datetime";

const props = defineProps<{ ctx: AppContext }>();

const allFiles = ref<Entry[]>([]);
const currentFolder = ref<string | null>(null);
const selectedId = ref<string | null>(null);
const folderPath = ref<{ id: string | null; name: string }[]>([{ id: null, name: "~" }]);
const dragover = ref(false);
const loading = ref(true);
const loadError = ref("");

function field<T = unknown>(e: Entry, k: string): T {
  return e.data[k] as T;
}
const fileName = (e: Entry) => field<string>(e, "filename") || "(unnamed)";
const isFolder = (e: Entry) => !!field(e, "is_folder");
const fileSize = (e: Entry) => field<number>(e, "size") || 0;
const parentId = (e: Entry) => field<string>(e, "parent_id") || null;
const filePath = (e: Entry) => field<string>(e, "path") || null;

function fileIcon(e: Entry): typeof Folder {
  if (isFolder(e)) return Folder;
  const mime = field<string>(e, "mime_type") || "";
  if (mime.startsWith("image/")) return ImageIcon;
  if (mime.startsWith("video/")) return Video;
  if (mime === "application/pdf" || mime.startsWith("text/")) return FileText;
  if (mime.includes("zip")) return FileArchive;
  return File;
}

const currentItems = computed(() =>
  allFiles.value
    .filter((f) => parentId(f) === currentFolder.value)
    .sort((a, b) => {
      const af = isFolder(a) ? 0 : 1;
      const bf = isFolder(b) ? 0 : 1;
      if (af !== bf) return af - bf;
      return fileName(a).toLowerCase().localeCompare(fileName(b).toLowerCase());
    }),
);

// ----- search + type filter -----

const searchQuery = ref("");
const typeFilter = ref("");

function matchesType(e: Entry): boolean {
  const mime = field<string>(e, "mime_type") || "";
  switch (typeFilter.value) {
    case "":
      return true;
    case "folder":
      return isFolder(e);
    case "image":
      return mime.startsWith("image/");
    case "video":
      return mime.startsWith("video/");
    case "doc":
      return mime === "application/pdf" || mime.startsWith("text/");
    case "archive":
      return mime.includes("zip");
    default:
      return (
        !isFolder(e) &&
        !mime.startsWith("image/") &&
        !mime.startsWith("video/") &&
        mime !== "application/pdf" &&
        !mime.startsWith("text/") &&
        !mime.includes("zip")
      );
  }
}

// ----- folder paths (for search results and history restore) -----

const byId = computed(() => new Map(allFiles.value.map((f) => [f.id, f])));

// Ancestor chain of a folder id, root first. The guard caps a corrupt
// parent_id cycle.
function chainTo(id: string | null): Entry[] {
  const chain: Entry[] = [];
  let cur = id ? byId.value.get(id) : undefined;
  let guard = 0;
  while (cur && guard++ < 50) {
    chain.unshift(cur);
    const pid = parentId(cur);
    cur = pid ? byId.value.get(pid) : undefined;
  }
  return chain;
}

function folderPathOf(e: Entry): string {
  const parts = chainTo(parentId(e)).map(fileName);
  return "~/" + parts.map((p) => p + "/").join("");
}

// Searching looks across the whole tree (flat results, files only);
// otherwise we list the current folder.
const displayed = computed(() => {
  const q = searchQuery.value.trim().toLowerCase();
  if (q) {
    return allFiles.value
      .filter((f) => !isFolder(f) && fileName(f).toLowerCase().includes(q) && matchesType(f))
      .sort((a, b) => fileName(a).toLowerCase().localeCompare(fileName(b).toLowerCase()));
  }
  return currentItems.value.filter(matchesType);
});

const selected = computed(() =>
  selectedId.value ? allFiles.value.find((f) => f.id === selectedId.value) || null : null,
);

async function reload() {
  loadError.value = "";
  try {
    allFiles.value = await props.ctx.api.entries.list({ kind: "file" });
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Failed to load files";
  } finally {
    loading.value = false;
  }
}

// Folder navigation goes through the browser history (?folder=<id>) so
// back/forward work as expected.
function setFolder(id: string | null, opts: { push?: boolean } = {}) {
  currentFolder.value = id;
  folderPath.value = [
    { id: null, name: "~" },
    ...chainTo(id).map((c) => ({ id: c.id as string | null, name: fileName(c) })),
  ];
  selectedId.value = null;
  if (opts.push) {
    history.pushState(null, "", id ? `/apps/files?folder=${id}` : "/apps/files");
  }
}

function navigateCrumb(idx: number) {
  setFolder(folderPath.value[idx].id, { push: true });
}

function openFolder(f: Entry) {
  if (!isFolder(f)) return;
  setFolder(f.id, { push: true });
}

// Jump from a search result to its containing folder.
function goToFolderOf(e: Entry) {
  searchQuery.value = "";
  setFolder(parentId(e), { push: true });
  selectedId.value = e.id;
}

function onPopState() {
  setFolder(new URLSearchParams(window.location.search).get("folder"));
}

async function newFolder() {
  const name = prompt("Folder name:");
  if (!name) return;
  await props.ctx.api.entries.create({
    kind: "file",
    source: "files_app",
    title: name,
    data: { filename: name, is_folder: true, parent_id: currentFolder.value },
  });
  await reload();
}

interface UploadProgress {
  index: number;
  total: number;
  name: string;
  pct: number; // whole-batch progress in bytes
  processing: boolean; // bytes sent, waiting on server work
}
const uploading = ref(false);
const uploadProgress = ref<UploadProgress | null>(null);
// One entry per failed file; a failure never aborts the rest of the batch.
const uploadErrors = ref<string[]>([]);

async function uploadFiles(files: File[]) {
  if (!files.length) return;
  uploading.value = true;
  uploadErrors.value = [];

  const totalBytes = files.reduce((sum, f) => sum + f.size, 0) || 1;
  let doneBytes = 0;

  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    uploadProgress.value = {
      index: i + 1,
      total: files.length,
      name: file.name,
      pct: Math.round((doneBytes / totalBytes) * 100),
      processing: false,
    };
    try {
      const result = await props.ctx.api.upload(file, "files", (pct) => {
        if (uploadProgress.value) {
          uploadProgress.value.pct = Math.round(
            ((doneBytes + (pct / 100) * file.size) / totalBytes) * 100,
          );
          uploadProgress.value.processing = pct >= 100;
        }
      });
      doneBytes += file.size;
      await props.ctx.api.entries.create({
        kind: "file",
        source: "files_app",
        title: file.name,
        data: {
          filename: file.name,
          size: result.size,
          mime_type: result.mime_type,
          path: result.path,
          parent_id: currentFolder.value,
          is_folder: false,
        },
      });
      // Refresh after each file so they appear as they land.
      await reload();
    } catch (e) {
      uploadErrors.value.push(`${file.name}: ${e instanceof Error ? e.message : "upload failed"}`);
    }
  }

  uploadProgress.value = null;
  uploading.value = false;
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement;
  if (input.files?.length) uploadFiles(Array.from(input.files));
  // Reset so picking the same file(s) again re-triggers the change event.
  input.value = "";
}

function onDrop(e: DragEvent) {
  dragover.value = false;
  if (e.dataTransfer?.files.length) uploadFiles(Array.from(e.dataTransfer.files));
}

async function deleteItem(f: Entry) {
  const ok = await props.ctx.confirm.ask({ message: "Delete this item?" });
  if (!ok) return;
  await props.ctx.api.entries.delete(f.id);
  selectedId.value = null;
  await reload();
}

onMounted(async () => {
  window.addEventListener("popstate", onPopState);
  await reload();
  const initial = new URLSearchParams(window.location.search).get("folder");
  if (initial) setFolder(initial);
});
onUnmounted(() => window.removeEventListener("popstate", onPopState));
</script>

<template>
  <p v-if="loading" class="fs-loading">Reading directory&hellip;</p>
  <p v-else-if="loadError" class="fs-loading">{{ loadError }}</p>
  <div v-else class="fs-layout">
    <div class="fs-main">
      <div class="fs-toolbar">
        <div class="fs-breadcrumbs">
          <template v-for="(p, i) in folderPath" :key="i">
            <span v-if="i > 0" class="fs-crumb-sep">/</span>
            <span class="fs-crumb" @click="navigateCrumb(i)">{{ p.name }}</span>
          </template>
        </div>
        <div class="fs-actions">
          <input
            v-model="searchQuery"
            class="fs-search"
            type="text"
            placeholder="Search files..."
          />
          <select v-model="typeFilter" class="fs-type-filter">
            <option value="">All types</option>
            <option value="folder">Folders</option>
            <option value="image">Images</option>
            <option value="video">Videos</option>
            <option value="doc">Documents</option>
            <option value="archive">Archives</option>
            <option value="other">Other</option>
          </select>
          <button class="fs-btn" @click="newFolder">+ Folder</button>
          <label class="fs-btn fs-upload-label">
            + Upload
            <input type="file" multiple hidden @change="onFileInput" />
          </label>
        </div>
      </div>
      <div v-if="uploading && uploadProgress" class="fs-uploading">
        <span class="fs-upload-count"
          >UPLOADING {{ uploadProgress.index }}/{{ uploadProgress.total }}</span
        >
        <span class="fs-upload-name">{{ uploadProgress.name }}</span>
        <span class="fs-upload-pct">{{
          uploadProgress.processing ? "processing…" : uploadProgress.pct + "%"
        }}</span>
        <div class="fs-upload-bar">
          <div class="fs-upload-bar-fill" :style="{ width: uploadProgress.pct + '%' }"></div>
        </div>
      </div>
      <div v-if="uploadErrors.length" class="fs-upload-errors" role="alert">
        <div v-for="(err, i) in uploadErrors" :key="i">{{ err }}</div>
        <button class="fs-upload-dismiss" @click="uploadErrors = []">Dismiss</button>
      </div>
      <div
        class="fs-list"
        :class="{ 'fs-dragover': dragover }"
        @dragover.prevent="dragover = true"
        @dragleave="dragover = false"
        @drop.prevent="onDrop"
      >
        <div class="fs-list-head" aria-hidden="true">
          <span></span>
          <span>Name</span>
          <span class="fs-col-size">Size</span>
          <span>Added</span>
        </div>
        <div
          v-for="f in displayed"
          :key="f.id"
          class="fs-row"
          :class="{ 'fs-row--active': f.id === selectedId }"
          @click="selectedId = f.id"
          @dblclick="openFolder(f)"
        >
          <span class="fs-row-icon" :class="{ 'fs-row-icon--folder': isFolder(f) }">
            <component :is="fileIcon(f)" :size="16" />
          </span>
          <span class="fs-name-cell">
            <span class="fs-name"
              >{{ fileName(f) }}<span v-if="isFolder(f)" class="fs-slash">/</span></span
            >
            <button
              v-if="searchQuery.trim()"
              class="fs-row-path"
              title="Go to folder"
              @click.stop="goToFolderOf(f)"
            >
              {{ folderPathOf(f) }}
            </button>
          </span>
          <span class="fs-size fs-col-size">{{
            isFolder(f) ? "—" : formatFileSize(fileSize(f))
          }}</span>
          <span class="fs-date">{{ formatDate(f.inserted_at) }}</span>
        </div>
        <p v-if="displayed.length === 0" class="fs-empty">
          {{ searchQuery || typeFilter ? "No match." : "Empty directory" }}
        </p>
      </div>
    </div>
    <div class="fs-detail-col">
      <div v-if="selected" class="fs-detail">
        <span class="fs-detail-icon" :class="{ 'fs-row-icon--folder': isFolder(selected) }">
          <component :is="fileIcon(selected)" :size="40" :stroke-width="1.5" />
        </span>
        <h3 class="fs-detail-name">{{ fileName(selected) }}</h3>
        <div v-if="!isFolder(selected)" class="fs-detail-meta">
          <div class="fs-meta-row">
            <span class="fs-meta-label">Size</span>
            <span>{{ formatFileSize(fileSize(selected)) }}</span>
          </div>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Type</span>
            <span>{{ field(selected, "mime_type") || "Unknown" }}</span>
          </div>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Added</span>
            <span>{{ formatDate(selected.inserted_at) }}</span>
          </div>
          <a
            v-if="filePath(selected)"
            class="fs-download"
            :href="filePath(selected)!"
            target="_blank"
            download
            >Download</a
          >
        </div>
        <div v-else class="fs-detail-meta">
          <div class="fs-meta-row">
            <span class="fs-meta-label">Type</span>
            <span>Folder</span>
          </div>
          <div class="fs-meta-row">
            <span class="fs-meta-label">Created</span>
            <span>{{ formatDate(selected.inserted_at) }}</span>
          </div>
        </div>
        <button class="fs-delete" @click="deleteItem(selected)">Delete</button>
      </div>
      <p v-else class="fs-placeholder">Select a file to view details</p>
    </div>
  </div>
</template>

<style scoped>
.fs-loading {
  color: var(--text-muted);
  padding: 2rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
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
/* The path is a prompt: ~/documents/taxes */
.fs-breadcrumbs {
  display: flex;
  align-items: center;
  gap: 0.15rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
  min-width: 0;
  overflow: hidden;
}
.fs-crumb {
  color: var(--text-muted);
  cursor: pointer;
  white-space: nowrap;
}
.fs-crumb:hover {
  color: var(--text);
}
.fs-crumb:first-child {
  color: var(--primary);
}
.fs-crumb:last-child {
  color: var(--text);
}
.fs-crumb-sep {
  color: var(--text-muted);
}
.fs-actions {
  display: flex;
  gap: 0.375rem;
  flex-shrink: 0;
  align-items: center;
}
.fs-search {
  width: 180px;
  padding: 0.4rem 0.65rem;
  font-size: 0.85rem;
  border-radius: 8px;
}
.fs-type-filter {
  width: auto;
  padding: 0.4rem 2rem 0.4rem 0.65rem;
  font-size: 0.85rem;
  border-radius: 8px;
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
.fs-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.fs-upload-label {
  display: inline-flex;
  align-items: center;
}
/* Upload progress + errors, same language as Photos */
.fs-uploading {
  display: flex;
  flex-wrap: wrap; /* the bar takes its own full row: label changes can't resize it */
  align-items: center;
  gap: 0.35rem 0.75rem;
  padding: 0.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.82rem;
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.08);
}
.fs-upload-count {
  letter-spacing: 0.08em;
  flex-shrink: 0;
}
.fs-upload-name {
  color: var(--text-muted);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.fs-upload-pct {
  flex-shrink: 0;
  margin-left: auto;
  text-align: right;
}
.fs-upload-bar {
  flex-basis: 100%;
  height: 6px;
  border-radius: 3px;
  background: rgba(var(--primary-rgb), 0.15);
  overflow: hidden;
}
.fs-upload-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 3px;
  transition: width 0.15s;
}
.fs-upload-errors {
  padding: 0.5rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.82rem;
  color: var(--danger);
  background: rgba(255, 92, 122, 0.08);
  display: flex;
  flex-direction: column;
  gap: 0.2rem;
}
.fs-upload-dismiss {
  align-self: flex-start;
  margin-top: 0.25rem;
  padding: 0.2rem 0.6rem;
  font-size: 0.78rem;
  background: transparent;
  border: 1px solid var(--danger);
  color: var(--danger);
  border-radius: 6px;
  cursor: pointer;
}
.fs-upload-dismiss:hover {
  background: var(--danger);
  color: #05070f;
}

/* Directory listing, ls style */
.fs-list {
  flex: 1;
  overflow-y: auto;
  padding: 0.5rem 0.75rem 0.75rem;
}
.fs-list-head,
.fs-row {
  display: grid;
  grid-template-columns: 24px minmax(0, 1fr) 120px 110px;
  gap: 1rem;
  align-items: center;
  padding: 0.35rem 0.5rem;
}
.fs-list-head {
  position: sticky;
  top: -0.5rem; /* cancel .fs-list padding */
  z-index: 2;
  background: var(--bg);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-muted);
  border-bottom: 1px solid var(--border);
}
.fs-row {
  border-radius: var(--radius);
  cursor: pointer;
  transition: background 0.1s;
}
.fs-row:hover {
  background: var(--bg-hover);
}
/* Cursor row: violet rail + tint, same language as Contacts */
.fs-row--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
}
.fs-row-icon {
  display: flex;
  align-items: center;
  color: var(--text-muted);
}
.fs-row-icon--folder {
  color: var(--primary);
}
.fs-name-cell {
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
}
.fs-name {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 100%;
}
.fs-row-path {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.72rem;
  color: var(--text-muted);
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 100%;
}
.fs-row-path:hover {
  color: var(--primary);
  background: none;
  text-decoration: underline;
}
.fs-slash {
  color: var(--text-muted);
}
.fs-size,
.fs-date {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.8rem;
  color: var(--text-muted);
  white-space: nowrap;
}
.fs-col-size {
  text-align: right;
}
.fs-list.fs-dragover {
  outline: 2px dashed var(--primary);
  outline-offset: -4px;
  background: rgba(var(--primary-rgb), 0.05);
}
.fs-empty {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}
.fs-placeholder {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem 1rem;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
}
.fs-detail {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.5rem;
}
.fs-detail-icon {
  color: var(--text-muted);
}
.fs-detail-name {
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.95rem;
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
.fs-meta-label {
  color: var(--text-muted);
}
.fs-download {
  display: block;
  text-align: center;
  margin-top: 0.75rem;
  color: var(--primary);
  text-decoration: none;
  font-size: 0.9rem;
}
.fs-download:hover {
  text-decoration: underline;
}
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
.fs-delete:hover {
  border-color: var(--danger);
  color: var(--danger);
}
</style>
