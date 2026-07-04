<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import type { AppContext, Entry } from "../types";
import { formatFileSize } from "../../types";
import { formatDate } from "../../lib/datetime";

const props = defineProps<{ ctx: AppContext }>();

const allFiles = ref<Entry[]>([]);
const currentFolder = ref<string | null>(null);
const selectedId = ref<string | null>(null);
const folderPath = ref<{ id: string | null; name: string }[]>([{ id: null, name: "Files" }]);
const dragover = ref(false);
const loading = ref(true);
const loadError = ref("");

const FILE_ICONS: Record<string, string> = {
  folder: "📁",
  pdf: "📄",
  image: "🖼️",
  text: "📝",
  zip: "📦",
  default: "📎",
};

function field<T = unknown>(e: Entry, k: string): T {
  return e.data[k] as T;
}
const fileName = (e: Entry) => field<string>(e, "filename") || "(unnamed)";
const isFolder = (e: Entry) => !!field(e, "is_folder");
const fileSize = (e: Entry) => field<number>(e, "size") || 0;
const parentId = (e: Entry) => field<string>(e, "parent_id") || null;
const filePath = (e: Entry) => field<string>(e, "path") || null;

function fileIcon(e: Entry): string {
  if (isFolder(e)) return FILE_ICONS.folder;
  const mime = field<string>(e, "mime_type") || "";
  if (mime.startsWith("image/")) return FILE_ICONS.image;
  if (mime === "application/pdf") return FILE_ICONS.pdf;
  if (mime.startsWith("text/")) return FILE_ICONS.text;
  if (mime.includes("zip")) return FILE_ICONS.zip;
  return FILE_ICONS.default;
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

function navigateCrumb(idx: number) {
  folderPath.value = folderPath.value.slice(0, idx + 1);
  currentFolder.value = folderPath.value[folderPath.value.length - 1].id;
  selectedId.value = null;
}

function openFolder(f: Entry) {
  if (!isFolder(f)) return;
  currentFolder.value = f.id;
  folderPath.value.push({ id: f.id, name: fileName(f) });
  selectedId.value = null;
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

async function uploadFiles(files: File[]) {
  for (const file of files) {
    const result = await props.ctx.api.upload(file, "files");
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
  }
  await reload();
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement;
  if (input.files?.length) uploadFiles(Array.from(input.files));
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

onMounted(reload);
</script>

<template>
  <p v-if="loading" class="fs-loading">Loading files...</p>
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
          <button class="fs-btn" @click="newFolder">+ Folder</button>
          <label class="fs-btn fs-upload-label">
            + Upload
            <input type="file" multiple hidden @change="onFileInput" />
          </label>
        </div>
      </div>
      <div
        class="fs-grid"
        :class="{ 'fs-dragover': dragover }"
        @dragover.prevent="dragover = true"
        @dragleave="dragover = false"
        @drop.prevent="onDrop"
      >
        <div
          v-for="f in currentItems"
          :key="f.id"
          class="fs-item"
          :class="{ 'fs-item--active': f.id === selectedId }"
          @click="selectedId = f.id"
          @dblclick="openFolder(f)"
        >
          <span class="fs-icon">{{ fileIcon(f) }}</span>
          <span class="fs-name">{{ fileName(f) }}</span>
          <span v-if="!isFolder(f)" class="fs-size">{{ formatFileSize(fileSize(f)) }}</span>
        </div>
        <p v-if="currentItems.length === 0" class="fs-empty">This folder is empty</p>
      </div>
    </div>
    <div class="fs-detail-col">
      <div v-if="selected" class="fs-detail">
        <span class="fs-detail-icon">{{ fileIcon(selected) }}</span>
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
.fs-crumb:hover {
  color: var(--text);
}
.fs-crumb:last-child {
  color: var(--text);
  font-weight: 500;
}
.fs-crumb-sep {
  color: var(--text-muted);
}
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
.fs-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.fs-upload-label {
  display: inline-flex;
  align-items: center;
}
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
.fs-item:hover {
  background: var(--bg-hover);
}
.fs-item--active {
  background: var(--bg-hover);
  outline: 1px solid var(--primary);
}
.fs-icon {
  font-size: 2rem;
  line-height: 1;
}
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
  background: rgba(var(--primary-rgb), 0.05);
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
.fs-detail-icon {
  font-size: 3rem;
}
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
