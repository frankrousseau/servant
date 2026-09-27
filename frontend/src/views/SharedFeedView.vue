<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { Play } from 'lucide-vue-next'

import MediaViewer from '../components/MediaViewer.vue'

import { fetchSharedFeed } from '../api/photoShares'
import { formatDate } from '../lib/datetime'
import type { ViewerItem } from '../apps/types'
import type { SharedFeed, SharedPhoto } from '../types'

const route = useRoute()

const feed = ref<SharedFeed | null>(null)
const loading = ref(true)
const missing = ref(false)
const loadError = ref('')
const viewerIndex = ref<number | null>(null)
const broken = ref<Set<string>>(new Set())

async function load() {
  loading.value = true
  missing.value = false
  loadError.value = ''
  try {
    const result = await fetchSharedFeed(String(route.params.token))
    if (result) feed.value = result
    else missing.value = true
  } catch (err) {
    loadError.value =
      err instanceof Error ? err.message : 'Failed to load the feed'
  } finally {
    loading.value = false
  }
}

watch(() => route.params.token, load, { immediate: true })

const title = computed(() => {
  if (!feed.value) return 'Shared photos'
  // A people-only link without a name: the feed withholds who it is about.
  return (
    feed.value.name ||
    feed.value.tags.map(tag => `#${tag}`).join(' ') ||
    'Shared photos'
  )
})

// The join word doubles as the match rule: "beach + family" needs both tags,
// "beach, family" either of them.
const tagLine = computed(() => {
  if (!feed.value) return ''
  const joiner = feed.value.match === 'all' ? ' + ' : ', '
  return feed.value.tags.map(tag => `#${tag}`).join(joiner)
})

const photos = computed(() => feed.value?.photos ?? [])

const cells = computed(() =>
  photos.value.map(photo => ({
    photo,
    showImage: !!photo.thumb && !broken.value.has(photo.id),
    alt: photo.title || (photo.video ? 'Video' : 'Photo'),
    date: photo.occurred_at ? formatDate(photo.occurred_at) : ''
  }))
)

const viewerItems = computed<ViewerItem[]>(() =>
  photos.value.map(photo => ({
    id: photo.id,
    src: photo.src || photo.thumb || '',
    fullSrc: photo.full || undefined,
    video: photo.video,
    title: photo.title || undefined,
    subtitle: photo.occurred_at ? formatDate(photo.occurred_at) : undefined,
    note: photo.note || undefined
  }))
)

function markBroken(photo: SharedPhoto) {
  broken.value = new Set(broken.value).add(photo.id)
}
</script>

<template>
  <div class="shared">
    <header class="shared-header">
      <div class="shared-brand">
        <img src="/logo.svg" alt="" class="shared-logo" />
        <span class="shared-brand-name">Servant</span>
      </div>
      <h1 class="shared-title">{{ title }}</h1>
      <p v-if="feed" class="shared-meta">
        <span class="shared-tags">{{ tagLine }}</span>
        <span class="shared-count"
          >{{ photos.length }}
          {{ photos.length === 1 ? 'item' : 'items' }}</span
        >
      </p>
    </header>

    <p v-if="loading" class="shared-state">Loading...</p>
    <p v-else-if="missing" class="shared-state">
      This link is no longer available.
    </p>
    <p v-else-if="loadError" class="shared-state shared-state--error">
      {{ loadError }}
    </p>
    <p v-else-if="photos.length === 0" class="shared-state">
      No photos in this feed yet.
    </p>

    <div v-else class="shared-grid">
      <button
        v-for="(cell, index) in cells"
        :key="cell.photo.id"
        type="button"
        class="shared-thumb"
        :title="cell.photo.title || cell.date"
        :autofocus="index === 0"
        @click="viewerIndex = index"
      >
        <img
          v-if="cell.showImage"
          :src="cell.photo.thumb || ''"
          :alt="cell.alt"
          loading="lazy"
          @error="markBroken(cell.photo)"
        />
        <span v-else class="shared-thumb-tile" aria-hidden="true">
          <Play v-if="cell.photo.video" :size="28" />
        </span>
        <span v-if="cell.photo.video && cell.showImage" class="shared-play">
          <Play :size="22" />
        </span>
      </button>
    </div>

    <MediaViewer
      v-if="viewerIndex !== null && viewerItems.length"
      :items="viewerItems"
      :start-index="viewerIndex"
      readonly
      @close="viewerIndex = null"
    />
  </div>
</template>

<style scoped>
.shared {
  max-width: 1200px;
  margin: 0 auto;
  padding: 1.5rem 1rem 3rem;
}

/* ----- Header ----- */
.shared-header {
  margin-bottom: 1.25rem;
}
.shared-brand {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  color: var(--text-muted);
  font-family: var(--font-display);
  font-size: 0.8rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: 0.75rem;
}
.shared-logo {
  width: 20px;
  height: 20px;
}
.shared-title {
  font-family: var(--font-display);
  font-weight: 400;
  font-size: 1.6rem;
  margin: 0 0 0.25rem;
  overflow-wrap: anywhere;
}
.shared-meta {
  display: flex;
  gap: 1rem;
  margin: 0;
  font-family: var(--font-mono);
  font-size: 0.85rem;
  color: var(--text-muted);
}
.shared-tags {
  color: var(--primary);
}

/* ----- States ----- */
.shared-state {
  color: var(--text-muted);
  font-family: var(--font-mono);
}
.shared-state--error {
  color: var(--danger);
}

/* ----- Grid ----- */
.shared-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 0.5rem;
}
.shared-thumb {
  position: relative;
  aspect-ratio: 1;
  border: none;
  padding: 0;
  border-radius: 8px;
  overflow: hidden;
  cursor: pointer;
  background: var(--bg-surface);
  transition: box-shadow 0.15s;
}
.shared-thumb:hover {
  box-shadow:
    0 0 0 2px rgba(var(--primary-rgb), 0.7),
    0 0 14px rgba(var(--primary-rgb), 0.25);
}
.shared-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.shared-thumb-tile {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-muted);
}
.shared-play {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  pointer-events: none;
  filter: drop-shadow(0 1px 3px rgba(0, 0, 0, 0.6));
}
</style>
