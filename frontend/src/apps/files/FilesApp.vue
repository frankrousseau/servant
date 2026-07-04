<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
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
          <button class="fs-btn" @click="newFolder">+ Folder</button>
          <label class="fs-btn fs-upload-label">
            + Upload
            <input type="file" multiple hidden @change="onFileInput" />
          </label>
        </div>
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
          v-for="f in currentItems"
          :key="f.id"
          class="fs-row"
          :class="{ 'fs-row--active': f.id === selectedId }"
          @click="selectedId = f.id"
          @dblclick="openFolder(f)"
        >
          <span class="fs-row-icon" :class="{ 'fs-row-icon--folder': isFolder(f) }">
            <component :is="fileIcon(f)" :size="16" />
          </span>
          <span class="fs-name"
            >{{ fileName(f) }}<span v-if="isFolder(f)" class="fs-slash">/</span></span
          >
          <span class="fs-size fs-col-size">{{
            isFolder(f) ? "—" : formatFileSize(fileSize(f))
          }}</span>
          <span class="fs-date">{{ formatDate(f.inserted_at) }}</span>
        </div>
        <p v-if="currentItems.length === 0" class="fs-empty">Empty directory</p>
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
/* Directory listing, ls style */
.fs-list {
  flex: 1;
  overflow-y: auto;
  padding: 0.5rem 0.75rem 0.75rem;
}
.fs-list-head,
.fs-row {
  display: grid;
  grid-template-columns: 24px minmax(0, 1fr) 90px 110px;
  gap: 0.6rem;
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
.fs-name {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
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
