<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ArrowLeft, Download, Trash2 } from 'lucide-vue-next'

import VideoPlayer from '../components/VideoPlayer.vue'

import { deleteEntry, getEntry } from '../api/entries'
import { useConfirm } from '../composables/useConfirm'
import { useFetchData } from '../composables/useFetchData'
import { formatDateTime } from '../lib/datetime'
import { formatFileSize } from '../lib/filesize'
import type { Entry } from '../types'

const route = useRoute()
const router = useRouter()

const {
  data: entry,
  loading,
  error,
  refetch
} = useFetchData<Entry>(() => getEntry(String(route.params.id)), {
  fallbackError: 'Photo not found'
})
const imgError = ref(false)
// Refetch when the id changes: the instance is reused across /photos/:id links.
watch(
  () => route.params.id,
  () => {
    imgError.value = false
    refetch()
  }
)

const photoPath = computed(() => (entry.value?.data?.path as string) || '')
const filename = computed(() => (entry.value?.data?.filename as string) || '')
const mimeType = computed(() => (entry.value?.data?.mime_type as string) || '')
const isVideo = computed(() => mimeType.value.startsWith('video/'))
const fileSize = computed(() =>
  formatFileSize((entry.value?.data?.size as number) || 0)
)
const album = computed(() => (entry.value?.data?.album as string) || '')
const dateTaken = computed(
  () => (entry.value?.data?.date_taken as string) || ''
)
const camera = computed(() => (entry.value?.data?.camera as string) || '')
const latitude = computed(
  () => entry.value?.data?.latitude as number | undefined
)
const longitude = computed(
  () => entry.value?.data?.longitude as number | undefined
)
const createdAt = computed(() => formatDateTime(entry.value?.inserted_at))

const { ask } = useConfirm()

async function deletePhoto() {
  if (!entry.value) return
  const ok = await ask({
    message: `Delete "${entry.value.title || 'this photo'}"?`
  })
  if (!ok) return
  await deleteEntry(entry.value.id)
  router.push('/apps/photos')
}
</script>

<template>
  <div class="view photo-detail">
    <div class="photo-topbar">
      <router-link
        v-autofocus
        to="/apps/photos"
        class="back-link"
        aria-label="Back to photos"
      >
        <ArrowLeft :size="20" />
      </router-link>
      <h1 v-if="entry">{{ entry.title || filename || 'Photo' }}</h1>
      <h1 v-else-if="loading">Loading...</h1>
    </div>

    <p v-if="error" class="photo-error">{{ error }}</p>

    <template v-if="entry && !loading">
      <div class="photo-layout">
        <div class="photo-preview">
          <VideoPlayer
            v-if="isVideo && !imgError"
            class="photo-player"
            :src="photoPath"
            @error="imgError = true"
          />
          <img
            v-else-if="!imgError"
            :src="photoPath"
            :alt="entry.title || ''"
            @error="imgError = true"
          />
          <div v-else class="photo-broken">
            <svg
              width="48"
              height="48"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <path d="m21 15-5-5L5 21" />
            </svg>
            <span>Image unavailable</span>
          </div>
        </div>
        <aside class="photo-info">
          <section class="photo-section">
            <h2>Details</h2>
            <div class="photo-meta">
              <div v-if="filename" class="meta-row">
                <span class="meta-key">Filename</span>
                <span>{{ filename }}</span>
              </div>
              <div v-if="mimeType" class="meta-row">
                <span class="meta-key">Type</span>
                <span>{{ mimeType }}</span>
              </div>
              <div v-if="fileSize" class="meta-row">
                <span class="meta-key">Size</span>
                <span>{{ fileSize }}</span>
              </div>
              <div v-if="album" class="meta-row">
                <span class="meta-key">Album</span>
                <span>{{ album }}</span>
              </div>
              <div v-if="dateTaken" class="meta-row">
                <span class="meta-key">Date taken</span>
                <span>{{ formatDateTime(dateTaken) }}</span>
              </div>
              <div v-if="camera" class="meta-row">
                <span class="meta-key">Camera</span>
                <span>{{ camera }}</span>
              </div>
              <div v-if="latitude != null" class="meta-row">
                <span class="meta-key">Location</span>
                <span
                  >{{ latitude!.toFixed(5) }}, {{ longitude!.toFixed(5) }}</span
                >
              </div>
            </div>
          </section>

          <section class="photo-section photo-section--muted">
            <h2>Info</h2>
            <div class="photo-meta">
              <div class="meta-row">
                <span class="meta-key">Added</span>
                <span>{{ createdAt }}</span>
              </div>
              <div class="meta-row">
                <span class="meta-key">Source</span>
                <span>{{ entry.source }}</span>
              </div>
              <div v-if="entry.external_id" class="meta-row">
                <span class="meta-key">External ID</span>
                <span class="mono">{{ entry.external_id }}</span>
              </div>
            </div>
          </section>

          <div class="photo-actions">
            <a :href="photoPath" download class="action-btn action-btn--ghost">
              <Download :size="15" /> Download
            </a>
            <button class="action-btn action-btn--danger" @click="deletePhoto">
              <Trash2 :size="15" /> Delete
            </button>
          </div>

          <div class="photo-permalink">
            <span class="meta-label">Permalink</span>
            <code>{{ `/photos/${entry.id}` }}</code>
          </div>
        </aside>
      </div>
    </template>
  </div>
</template>

<style scoped>
.photo-detail {
  max-width: none;
}

.photo-topbar {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.photo-topbar h1 {
  margin: 0;
  font-size: 1.25rem;
}

.back-link {
  color: var(--text-muted);
  display: flex;
}

.back-link:hover {
  color: var(--text);
}

.photo-error {
  color: var(--danger);
}

.photo-layout {
  display: flex;
  gap: 1.5rem;
  align-items: flex-start;
}

.photo-preview {
  flex: 1;
  min-width: 0;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
}

.photo-preview img {
  max-width: 100%;
  max-height: calc(100vh - 12rem);
  object-fit: contain;
  display: block;
}
.photo-player {
  width: 100%;
  aspect-ratio: 16 / 9;
  max-height: calc(100vh - 12rem);
  border-radius: 8px;
}

.photo-broken {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  padding: 4rem;
  color: var(--text-muted);
  opacity: 0.5;
  font-size: 0.9rem;
}

.photo-info {
  width: 300px;
  flex-shrink: 0;
}

.photo-section {
  margin-bottom: 1.25rem;
}

.photo-section--muted {
  opacity: 0.7;
}

.photo-info h2 {
  font-size: 0.85rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
  margin: 0 0 0.75rem;
}

.photo-meta {
  display: flex;
  flex-direction: column;
}

.meta-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  padding: 0.45rem 0;
  border-bottom: 1px solid var(--border);
  font-size: 0.9rem;
  gap: 1rem;
}

.meta-key {
  color: var(--text-muted);
  flex-shrink: 0;
}

.meta-row > span:last-child {
  text-align: right;
  word-break: break-all;
}

.mono {
  font-family: var(--font-mono);
  font-size: 0.85rem;
}

.photo-actions {
  display: flex;
  gap: 0.375rem;
  margin-top: 1rem;
}

.action-btn {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.35rem 0.8rem;
  font-size: 0.85rem;
  font-weight: 500;
  border-radius: var(--control-radius);
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s,
    border-color 0.15s;
  white-space: nowrap;
  text-decoration: none;
}

.action-btn--ghost {
  background: transparent;
  color: var(--text-muted);
  border: 1px solid var(--border);
}

.action-btn--ghost:hover {
  color: var(--text);
  border-color: var(--text-muted);
  background: var(--bg-hover);
}

.action-btn--danger {
  background: transparent;
  color: var(--text-muted);
  border: 1px solid var(--border);
}

.action-btn--danger:hover {
  color: var(--danger);
  border-color: var(--danger);
  background: color-mix(in srgb, var(--danger) 8%, transparent);
}

.photo-permalink {
  margin-top: 1.25rem;
  padding-top: 0.75rem;
  border-top: 1px solid var(--border);
}

.meta-label {
  display: block;
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-muted);
  margin-bottom: 0.25rem;
}

.photo-permalink code {
  font-size: 0.85rem;
  color: var(--primary);
  word-break: break-all;
}
</style>
