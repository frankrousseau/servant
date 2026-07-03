<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted } from "vue";
import type { AppContext, Entry } from "../types";
import { formatFileSize } from "../../types";
import { formatDateTime } from "../../lib/datetime";

const props = defineProps<{ ctx: AppContext }>();

interface Person {
  id: string;
  name: string;
}

const allPhotos = ref<Entry[]>([]);
const allContacts = ref<Entry[]>([]);
const albumFilter = ref("");
const tagFilter = ref("");
const peopleFilter = ref("");
const uploading = ref(false);
const loading = ref(true);
const loadError = ref("");
const selectionMode = ref(false);
const peopleSearchActive = ref(false);
const peopleSearchQuery = ref("");
const tagModalActive = ref(false);
const tagModalQuery = ref("");
const selectedIds = ref<Set<string>>(new Set());
const broken = ref<Set<string>>(new Set());

const peopleInput = ref<HTMLInputElement | null>(null);
const tagInput = ref<HTMLInputElement | null>(null);

function field(e: Entry, k: string): unknown {
  return e.data[k];
}
const getThumbPath = (e: Entry) => (field(e, "thumb_path") || field(e, "path")) as string;
const getTags = (e: Entry): string[] => (e.data.tags as string[]) || [];
const getPeople = (e: Entry): Person[] => (e.data.people as Person[]) || [];

const albums = computed(() => {
  const set = new Set<string>();
  for (const p of allPhotos.value) {
    const a = field(p, "album") as string;
    if (a) set.add(a);
  }
  return Array.from(set).sort();
});

const allTags = computed(() => {
  const set = new Set<string>();
  for (const p of allPhotos.value) for (const t of getTags(p)) set.add(t);
  return Array.from(set).sort();
});

const allPeople = computed<Person[]>(() => {
  const map = new Map<string, string>();
  for (const p of allPhotos.value) for (const person of getPeople(p)) map.set(person.id, person.name);
  return Array.from(map.entries())
    .map(([id, name]) => ({ id, name }))
    .sort((a, b) => a.name.localeCompare(b.name));
});

const filtered = computed(() => {
  let list = allPhotos.value;
  if (albumFilter.value) list = list.filter((p) => field(p, "album") === albumFilter.value);
  if (tagFilter.value) list = list.filter((p) => getTags(p).includes(tagFilter.value));
  if (peopleFilter.value) list = list.filter((p) => getPeople(p).some((pp) => pp.id === peopleFilter.value));
  return list;
});

const selCount = computed(() => selectedIds.value.size);
const hasFilters = computed(() => allTags.value.length > 0 || allPeople.value.length > 0);

const matchingContacts = computed(() => {
  if (!peopleSearchActive.value || peopleSearchQuery.value.length < 1) return [];
  const q = peopleSearchQuery.value.toLowerCase();
  return allContacts.value
    .filter((c) => ((c.data.display_name as string) || c.title || "").toLowerCase().includes(q))
    .slice(0, 8);
});

const currentTags = computed(() => {
  const counts = new Set<string>();
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find((p) => p.id === id);
    if (photo) for (const t of getTags(photo)) counts.add(t);
  }
  return Array.from(counts).sort();
});

const tagSuggestions = computed(() => {
  if (!tagModalQuery.value) return allTags.value;
  const q = tagModalQuery.value.toLowerCase();
  return allTags.value.filter((t) => t.toLowerCase().includes(q) && t.toLowerCase() !== q);
});

function contactName(c: Entry): string {
  return (c.data.display_name as string) || c.title?.split(" — ")[0] || "(unnamed)";
}
function contactInitials(c: Entry): string {
  return contactName(c)
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() || "")
    .join("");
}

function setFilter(opts: { tag?: string; person?: string }) {
  if (opts.tag !== undefined) {
    tagFilter.value = opts.tag;
    peopleFilter.value = "";
  }
  if (opts.person !== undefined) {
    peopleFilter.value = opts.person;
    tagFilter.value = "";
  }
  if (opts.tag === "" && opts.person === "") {
    tagFilter.value = "";
    peopleFilter.value = "";
  }
}

async function reload() {
  loadError.value = "";
  try {
    const [photos, contacts] = await Promise.all([
      props.ctx.api.entries.list({ kind: "photo" }),
      allContacts.value.length
        ? Promise.resolve(allContacts.value)
        : props.ctx.api.entries.list({ kind: "contact" }),
    ]);
    allPhotos.value = photos.sort(
      (a, b) => new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime(),
    );
    allContacts.value = contacts;
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Failed to load photos";
  } finally {
    loading.value = false;
  }
}

async function uploadFiles(files: File[]) {
  const images = files.filter((f) => f.type.startsWith("image/"));
  if (!images.length) return;
  uploading.value = true;
  loadError.value = "";
  try {
    for (const file of images) {
      const result = (await props.ctx.api.upload(file, "photos")) as unknown as Record<string, unknown>;
      const data: Record<string, unknown> = {
        filename: file.name,
        size: result.size,
        mime_type: result.mime_type,
        path: result.path,
        album: albumFilter.value || null,
        tags: [],
      };
      if (result.date_taken) data.date_taken = result.date_taken;
      if (result.latitude != null) {
        data.latitude = result.latitude;
        data.longitude = result.longitude;
      }
      if (result.camera) data.camera = result.camera;
      if (result.thumb_path) data.thumb_path = result.thumb_path;

      await props.ctx.api.entries.create({
        kind: "photo",
        source: "photos_app",
        title: file.name,
        occurred_at: (result.date_taken as string) || null,
        data,
      });
    }
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Upload failed";
  } finally {
    uploading.value = false;
  }
  await reload();
}

function onFileInput(e: Event) {
  const input = e.target as HTMLInputElement;
  if (input.files?.length) uploadFiles(Array.from(input.files));
}
const dragover = ref(false);
function onDrop(e: DragEvent) {
  dragover.value = false;
  if (e.dataTransfer?.files.length) uploadFiles(Array.from(e.dataTransfer.files));
}

function onThumbClick(p: Entry) {
  if (selectionMode.value) {
    if (selectedIds.value.has(p.id)) selectedIds.value.delete(p.id);
    else selectedIds.value.add(p.id);
  } else {
    openViewer(p.id);
  }
}

function enterSelect() {
  selectionMode.value = true;
  selectedIds.value.clear();
}
function cancelSelect() {
  selectionMode.value = false;
  selectedIds.value.clear();
  peopleSearchActive.value = false;
}
function selectAll() {
  for (const p of filtered.value) selectedIds.value.add(p.id);
}
function deselect() {
  selectedIds.value.clear();
}

async function deletePhotos(ids: string[]) {
  if (!ids.length) return;
  const label = ids.length === 1 ? "this photo" : `${ids.length} photos`;
  const ok = await props.ctx.confirm.ask({ message: `Delete ${label}?`, danger: true, confirmLabel: "Delete" });
  if (!ok) return;
  loadError.value = "";
  try {
    for (const id of ids) await props.ctx.api.entries.delete(id);
  } catch (e) {
    loadError.value = e instanceof Error ? e.message : "Delete failed";
  }
  selectedIds.value.clear();
  selectionMode.value = false;
  await reload();
}

function openTagPeople() {
  peopleSearchActive.value = true;
  peopleSearchQuery.value = "";
  nextTick(() => peopleInput.value?.focus());
}
function onPeopleKeydown(e: KeyboardEvent) {
  if (e.key === "Escape") {
    peopleSearchActive.value = false;
    peopleSearchQuery.value = "";
  }
}
async function tagWithContact(c: Entry) {
  const name = contactName(c);
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find((p) => p.id === id);
    if (!photo) continue;
    const existing = getPeople(photo);
    if (existing.some((pp) => pp.id === c.id)) continue;
    await props.ctx.api.entries.update(id, {
      data: { ...photo.data, people: [...existing, { id: c.id, name }] },
    });
  }
  peopleSearchActive.value = false;
  peopleSearchQuery.value = "";
  selectedIds.value.clear();
  selectionMode.value = false;
  await reload();
}

function openTagModal() {
  tagModalActive.value = true;
  tagModalQuery.value = "";
  nextTick(() => tagInput.value?.focus());
}
function closeTagModal() {
  tagModalActive.value = false;
  tagModalQuery.value = "";
}
async function applyTag(tag: string) {
  const t = tag.trim();
  if (!t) return;
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find((p) => p.id === id);
    if (!photo) continue;
    const existing = getTags(photo);
    if (existing.includes(t)) continue;
    await props.ctx.api.entries.update(id, { data: { ...photo.data, tags: [...existing, t] } });
  }
  tagModalActive.value = false;
  tagModalQuery.value = "";
  selectedIds.value.clear();
  selectionMode.value = false;
  await reload();
}
async function removeTagFromSelected(tag: string) {
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find((p) => p.id === id);
    if (!photo) continue;
    const existing = getTags(photo);
    if (!existing.includes(tag)) continue;
    await props.ctx.api.entries.update(id, { data: { ...photo.data, tags: existing.filter((t) => t !== tag) } });
  }
  const photos = await props.ctx.api.entries.list({ kind: "photo" });
  allPhotos.value = photos.sort((a, b) => new Date(b.inserted_at).getTime() - new Date(a.inserted_at).getTime());
  nextTick(() => tagInput.value?.focus());
}
async function removeTagAction() {
  if (!tagFilter.value) return;
  for (const id of selectedIds.value) {
    const photo = allPhotos.value.find((p) => p.id === id);
    if (!photo) continue;
    const existing = getTags(photo);
    await props.ctx.api.entries.update(id, {
      data: { ...photo.data, tags: existing.filter((t) => t !== tagFilter.value) },
    });
  }
  selectedIds.value.clear();
  selectionMode.value = false;
  await reload();
}

function openViewer(photoId: string) {
  const photos = filtered.value;
  const items = photos.map((p) => {
    const meta: Record<string, string | number | null> = {};
    if (p.data.date_taken) meta["Date taken"] = formatDateTime(p.data.date_taken as string);
    if (p.data.camera) meta["Camera"] = p.data.camera as string;
    if (p.data.latitude != null)
      meta["Location"] = `${(p.data.latitude as number).toFixed(5)}, ${(p.data.longitude as number).toFixed(5)}`;
    if (p.data.size) meta["Size"] = formatFileSize(p.data.size as number);
    if (p.data.filename) meta["Filename"] = p.data.filename as string;
    if (p.data.album) meta["Album"] = p.data.album as string;
    const tags = getTags(p);
    if (tags.length) meta["Tags"] = tags.join(", ");
    const photoPeople = getPeople(p);
    if (photoPeople.length) meta["People"] = photoPeople.map((pp) => pp.name).join(", ");
    return {
      id: p.id,
      src: field(p, "path") as string,
      title: p.title || undefined,
      subtitle: (field(p, "album") as string) || undefined,
      meta: Object.keys(meta).length ? meta : undefined,
    };
  });
  const idx = photos.findIndex((p) => p.id === photoId);
  props.ctx.viewer.open(items, Math.max(0, idx));
}

watch(peopleSearchActive, (active) => {
  if (active) nextTick(() => peopleInput.value?.focus());
});

onMounted(() => {
  props.ctx.viewer.onDelete(async (id) => {
    await props.ctx.api.entries.delete(id);
    await reload();
  });
  reload();
});
</script>

<template>
  <p v-if="loading" class="ph-loading">Loading photos...</p>
  <p v-else-if="loadError" class="ph-loading">{{ loadError }}</p>
  <div
    v-else
    class="ph-layout"
    :class="{ 'ph-dragover': dragover }"
    @dragover.prevent="dragover = true"
    @dragleave="dragover = false"
    @drop.prevent="onDrop"
  >
    <!-- Selection toolbar -->
    <div v-if="selectionMode" class="ph-toolbar">
      <span class="ph-sel-count">{{ selCount }} selected</span>
      <div class="ph-actions">
        <button class="ph-btn" @click="selectAll">Select all</button>
        <button class="ph-btn" @click="deselect">Deselect</button>
        <button class="ph-btn ph-btn--primary" :disabled="selCount === 0" @click="openTagModal">Tag</button>
        <button class="ph-btn" :disabled="selCount === 0" @click="openTagPeople">Tag people</button>
        <button class="ph-btn ph-btn--danger" :disabled="selCount === 0" @click="deletePhotos([...selectedIds])">
          Delete
        </button>
        <button
          v-if="tagFilter"
          class="ph-btn ph-btn--danger"
          :disabled="selCount === 0"
          @click="removeTagAction"
        >
          Remove "{{ tagFilter }}"
        </button>
        <button class="ph-btn" @click="cancelSelect">Cancel</button>
      </div>
    </div>
    <div v-if="selectionMode && peopleSearchActive" class="ph-people-search">
      <input
        ref="peopleInput"
        class="ph-people-input"
        type="text"
        placeholder="Search contacts..."
        v-model="peopleSearchQuery"
        @keydown="onPeopleKeydown"
      />
      <div v-if="matchingContacts.length" class="ph-people-results">
        <div
          v-for="c in matchingContacts"
          :key="c.id"
          class="ph-people-result"
          @click="tagWithContact(c)"
        >
          <img v-if="c.data.photo" class="ph-people-avatar" :src="(c.data.photo as string)" alt="" />
          <span v-else class="ph-people-avatar ph-people-avatar--init">{{ contactInitials(c) }}</span>
          <span>{{ contactName(c) }}</span>
        </div>
      </div>
      <div v-else-if="peopleSearchQuery" class="ph-people-no-results">No contacts found</div>
    </div>

    <!-- Normal toolbar -->
    <div v-if="!selectionMode" class="ph-toolbar">
      <div class="ph-filters">
        <select class="ph-album-filter" v-model="albumFilter">
          <option value="">All photos ({{ allPhotos.length }})</option>
          <option v-for="a in albums" :key="a" :value="a">{{ a }}</option>
        </select>
      </div>
      <div class="ph-actions">
        <button class="ph-btn" @click="enterSelect">Select</button>
        <label class="ph-btn">
          + Upload<input type="file" accept="image/*" multiple hidden @change="onFileInput" />
        </label>
      </div>
    </div>

    <!-- Tag / people filter bar -->
    <div v-if="hasFilters" class="ph-tags-bar">
      <span
        class="ph-tag-pill"
        :class="{ 'ph-tag-pill--active': !tagFilter && !peopleFilter }"
        @click="setFilter({ tag: '', person: '' })"
        >All</span
      >
      <span
        v-for="t in allTags"
        :key="'t' + t"
        class="ph-tag-pill"
        :class="{ 'ph-tag-pill--active': t === tagFilter }"
        @click="setFilter({ tag: t })"
        >{{ t }}</span
      >
      <span v-if="allPeople.length" class="ph-tag-sep"></span>
      <span
        v-for="p in allPeople"
        :key="'p' + p.id"
        class="ph-tag-pill ph-tag-pill--person"
        :class="{ 'ph-tag-pill--active': p.id === peopleFilter }"
        @click="setFilter({ person: p.id })"
        >{{ p.name }}</span
      >
    </div>

    <div v-if="uploading" class="ph-uploading">Uploading...</div>

    <div class="ph-grid">
      <div
        v-for="p in filtered"
        :key="p.id"
        class="ph-thumb"
        :class="{ 'ph-thumb--selected': selectionMode && selectedIds.has(p.id) }"
        @click="onThumbClick(p)"
      >
        <span
          v-if="selectionMode"
          class="ph-check"
          :class="{ 'ph-check--on': selectedIds.has(p.id) }"
        ></span>
        <button v-else class="ph-thumb-delete" title="Delete" @click.stop="deletePhotos([p.id])">×</button>
        <img
          v-if="!broken.has(p.id)"
          class="ph-thumb-img"
          :src="getThumbPath(p)"
          :alt="p.title || ''"
          loading="lazy"
          @error="broken.add(p.id)"
        />
        <div v-else class="ph-broken">
          <svg
            width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor"
            stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
          >
            <rect x="3" y="3" width="18" height="18" rx="2" />
            <circle cx="8.5" cy="8.5" r="1.5" />
            <path d="m21 15-5-5L5 21" />
          </svg>
        </div>
        <div v-if="getTags(p).length || getPeople(p).length" class="ph-thumb-tags">
          <span v-for="t in getTags(p)" :key="'t' + t" class="ph-thumb-tag">{{ t }}</span>
          <span
            v-for="pp in getPeople(p)"
            :key="'pp' + pp.id"
            class="ph-thumb-tag ph-thumb-tag--person"
            >{{ pp.name }}</span
          >
        </div>
      </div>
      <p v-if="filtered.length === 0" class="ph-empty">No photos found.</p>
    </div>
  </div>

  <Teleport to="body">
    <div v-if="tagModalActive" class="ph-modal-overlay" @click.self="closeTagModal">
      <div class="ph-modal">
        <h3 class="ph-modal-title">Tags</h3>
        <template v-if="currentTags.length">
          <div class="ph-modal-section-label">Current tags</div>
          <div class="ph-modal-current-tags">
            <span v-for="t in currentTags" :key="t" class="ph-modal-current-tag">
              {{ t }}
              <span class="ph-modal-tag-remove" @click.stop="removeTagFromSelected(t)">×</span>
            </span>
          </div>
        </template>
        <div class="ph-modal-section-label">Add a tag</div>
        <input
          ref="tagInput"
          class="ph-modal-input"
          type="text"
          placeholder="Tag name..."
          v-model="tagModalQuery"
          @keydown.enter="applyTag(tagModalQuery)"
          @keydown.esc="closeTagModal"
        />
        <div v-if="tagSuggestions.length" class="ph-modal-suggestions">
          <span
            v-for="t in tagSuggestions"
            :key="t"
            class="ph-modal-suggestion"
            @click="applyTag(t)"
            >{{ t }}</span
          >
        </div>
        <div class="ph-modal-actions">
          <button class="ph-btn" @click="closeTagModal">Cancel</button>
          <button class="ph-btn ph-btn--primary" :disabled="!tagModalQuery.trim()" @click="applyTag(tagModalQuery)">
            Add
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.ph-loading {
  color: var(--text-muted);
  padding: 2rem;
}
.ph-layout {
  display: flex;
  flex-direction: column;
  height: calc(100vh - 4rem);
}
.ph-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid var(--border);
  gap: 0.5rem;
}
.ph-filters {
  display: flex;
  gap: 0.5rem;
  align-items: center;
}
.ph-album-filter {
  width: auto;
  min-width: 180px;
}
.ph-sel-count {
  font-size: 0.9rem;
  color: var(--text-muted);
}
.ph-actions {
  display: flex;
  gap: 0.375rem;
  flex-shrink: 0;
}
.ph-btn {
  display: inline-flex;
  align-items: center;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-muted);
  padding: 0.4rem 0.75rem;
  border-radius: 8px;
  cursor: pointer;
  font-size: 0.85rem;
  white-space: nowrap;
}
.ph-btn:hover {
  border-color: var(--primary);
  color: var(--text);
}
.ph-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.ph-btn:disabled:hover {
  border-color: var(--border);
  color: var(--text-muted);
}
.ph-btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: #fff;
}
.ph-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}
.ph-btn--danger {
  color: var(--danger);
  border-color: var(--danger);
}
.ph-btn--danger:hover {
  background: rgba(240, 108, 108, 0.08);
}
.ph-tags-bar {
  display: flex;
  gap: 0.375rem;
  padding: 0.5rem 1rem;
  border-bottom: 1px solid var(--border);
  overflow-x: auto;
  flex-shrink: 0;
}
.ph-tag-pill {
  padding: 0.2rem 0.6rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--bg-hover);
  color: var(--text-muted);
  cursor: pointer;
  white-space: nowrap;
  transition: background 0.1s, color 0.1s;
}
.ph-tag-pill:hover {
  color: var(--text);
}
.ph-tag-pill--active {
  background: var(--primary);
  color: #fff;
}
.ph-people-search {
  padding: 0.5rem 1rem;
  border-bottom: 1px solid var(--border);
  position: relative;
}
.ph-people-input {
  width: 100%;
}
.ph-people-results {
  position: absolute;
  top: 100%;
  left: 1rem;
  right: 1rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  max-height: 240px;
  overflow-y: auto;
  z-index: 10;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
}
.ph-people-result {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  padding: 0.5rem 0.75rem;
  cursor: pointer;
  transition: background 0.1s;
}
.ph-people-result:hover {
  background: var(--bg-hover);
}
.ph-people-avatar {
  width: 28px;
  height: 28px;
  border-radius: 50%;
  object-fit: cover;
  flex-shrink: 0;
}
.ph-people-avatar--init {
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
  font-size: 0.7rem;
  font-weight: 600;
}
.ph-people-no-results {
  padding: 0.75rem;
  color: var(--text-muted);
  font-size: 0.85rem;
  text-align: center;
}
.ph-tag-sep {
  width: 1px;
  height: 16px;
  background: var(--border);
  flex-shrink: 0;
  align-self: center;
}
.ph-tag-pill--person {
  background: rgba(108, 206, 201, 0.15);
  color: #6ccec9;
}
.ph-tag-pill--person.ph-tag-pill--active {
  background: #6ccec9;
  color: #000;
}
.ph-thumb-tag--person {
  background: rgba(108, 206, 201, 0.7);
}
.ph-uploading {
  padding: 0.5rem 1rem;
  font-size: 0.85rem;
  color: var(--primary);
  background: rgba(108, 140, 255, 0.08);
}
.ph-grid {
  flex: 1;
  overflow-y: auto;
  padding: 0.75rem;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 0.5rem;
  align-content: start;
}
.ph-thumb {
  position: relative;
  aspect-ratio: 1;
  border-radius: 8px;
  overflow: hidden;
  cursor: pointer;
  background: var(--bg-surface);
  transition: transform 0.15s;
}
.ph-thumb:hover {
  transform: scale(1.03);
}
.ph-thumb--selected {
  outline: 3px solid var(--primary);
  outline-offset: -3px;
}
.ph-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.ph-thumb-delete {
  position: absolute;
  top: 6px;
  right: 6px;
  z-index: 2;
  width: 26px;
  height: 26px;
  border: none;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.65);
  color: #fff;
  font-size: 1.1rem;
  line-height: 1;
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.15s;
}
.ph-thumb:hover .ph-thumb-delete {
  opacity: 1;
}
.ph-thumb-delete:hover {
  background: var(--danger);
}
.ph-check {
  position: absolute;
  top: 6px;
  left: 6px;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 2px solid rgba(255, 255, 255, 0.6);
  background: rgba(0, 0, 0, 0.3);
  z-index: 2;
  pointer-events: none;
}
.ph-check--on {
  background: var(--primary);
  border-color: var(--primary);
}
.ph-check--on::after {
  content: "";
  position: absolute;
  top: 4px;
  left: 6px;
  width: 5px;
  height: 9px;
  border: solid #fff;
  border-width: 0 2px 2px 0;
  transform: rotate(45deg);
}
.ph-thumb-tags {
  position: absolute;
  bottom: 4px;
  left: 4px;
  right: 4px;
  display: flex;
  gap: 3px;
  flex-wrap: wrap;
  z-index: 1;
}
.ph-thumb-tag {
  font-size: 0.65rem;
  padding: 0.1rem 0.4rem;
  background: rgba(0, 0, 0, 0.6);
  color: #fff;
  border-radius: 4px;
  white-space: nowrap;
}
.ph-layout.ph-dragover {
  outline: 2px dashed var(--primary);
  outline-offset: -4px;
  background: rgba(108, 140, 255, 0.05);
}
.ph-broken {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-muted);
  opacity: 0.4;
  background: var(--bg-hover);
}
.ph-empty {
  color: var(--text-muted);
  text-align: center;
  padding: 3rem;
  grid-column: 1 / -1;
}
.ph-modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
}
.ph-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  width: 100%;
  max-width: 360px;
}
.ph-modal-title {
  margin: 0 0 1rem;
  font-size: 1.1rem;
}
.ph-modal-input {
  width: 100%;
  margin-bottom: 0.75rem;
}
.ph-modal-suggestions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin-bottom: 1rem;
}
.ph-modal-suggestion {
  padding: 0.2rem 0.6rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--bg-hover);
  color: var(--text-muted);
  cursor: pointer;
  transition: background 0.1s, color 0.1s;
}
.ph-modal-suggestion:hover {
  background: var(--primary);
  color: #fff;
}
.ph-modal-section-label {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: uppercase;
  letter-spacing: 0.03em;
  margin-bottom: 0.4rem;
}
.ph-modal-current-tags {
  display: flex;
  flex-wrap: wrap;
  gap: 0.375rem;
  margin-bottom: 1rem;
}
.ph-modal-current-tag {
  display: inline-flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.2rem 0.5rem;
  border-radius: 20px;
  font-size: 0.8rem;
  background: var(--primary);
  color: #fff;
}
.ph-modal-tag-remove {
  cursor: pointer;
  font-size: 1rem;
  line-height: 1;
  opacity: 0.7;
  transition: opacity 0.1s;
}
.ph-modal-tag-remove:hover {
  opacity: 1;
}
.ph-modal-actions {
  display: flex;
  gap: 0.5rem;
  justify-content: flex-end;
}
</style>
