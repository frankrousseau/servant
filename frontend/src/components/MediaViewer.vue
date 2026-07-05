<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import {
  ChevronLeft,
  ChevronRight,
  X,
  Download,
  Trash2,
  ZoomIn,
  ZoomOut,
  ExternalLink,
  Info,
  Maximize2
} from 'lucide-vue-next'
import { useConfirm } from '../composables/useConfirm'
import VideoPlayer from './VideoPlayer.vue'

export interface ViewerItem {
  id: string
  src: string
  /** Original full-resolution source when `src` is a downscaled display copy. */
  fullSrc?: string
  video?: boolean
  title?: string
  subtitle?: string
  meta?: Record<string, string | number | null>
}

const props = defineProps<{
  items: ViewerItem[]
  startIndex?: number
}>()

const emit = defineEmits<{
  close: []
  delete: [id: string]
}>()

const currentIndex = ref(props.startIndex ?? 0)
const zoom = ref(1)
const imgError = ref(false)
const showInfo = ref(false)
const showFull = ref(false)

const current = computed(() => props.items[currentIndex.value])
const displaySrc = computed(() =>
  showFull.value && current.value?.fullSrc
    ? current.value.fullSrc
    : current.value?.src
)
const hasPrev = computed(() => currentIndex.value > 0)
const hasNext = computed(() => currentIndex.value < props.items.length - 1)

// Keep the index in range when items shrink (e.g. deleting the last item while
// the viewer is open) so `current` doesn't become undefined ("Image
// unavailable" + a bogus "3 / 2" counter).
watch(
  () => props.items.length,
  len => {
    if (len === 0) {
      emit('close')
    } else if (currentIndex.value > len - 1) {
      currentIndex.value = len - 1
    }
  }
)

function prev() {
  if (hasPrev.value) {
    currentIndex.value--
    zoom.value = 1
    imgError.value = false
    showInfo.value = false
    showFull.value = false
  }
}

function next() {
  if (hasNext.value) {
    currentIndex.value++
    zoom.value = 1
    imgError.value = false
    showInfo.value = false
    showFull.value = false
  }
}

function zoomIn() {
  zoom.value = Math.min(zoom.value + 0.5, 5)
}

function zoomOut() {
  zoom.value = Math.max(zoom.value - 0.5, 0.5)
}

const { ask } = useConfirm()

async function handleDelete() {
  if (!current.value) return
  const ok = await ask({
    message: `Delete "${current.value.title || 'this item'}"?`
  })
  if (ok) emit('delete', current.value.id)
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') emit('close')
  else if (e.key === 'ArrowLeft') prev()
  else if (e.key === 'ArrowRight') next()
  else if (e.key === '+' || e.key === '=') zoomIn()
  else if (e.key === '-') zoomOut()
}

onMounted(() => document.addEventListener('keydown', onKeydown))
onUnmounted(() => document.removeEventListener('keydown', onKeydown))
</script>

<template>
  <Teleport to="body">
    <div class="mv-overlay" @click.self="emit('close')">
      <!-- Main image / video -->
      <div class="mv-stage">
        <VideoPlayer
          v-if="current && current.video && !imgError"
          :key="current.id"
          class="mv-player"
          :src="current.src"
          autoplay
          @error="imgError = true"
        />
        <img
          v-else-if="current && !imgError"
          :src="displaySrc"
          :alt="current.title || ''"
          class="mv-image"
          :style="{ transform: `scale(${zoom})` }"
          draggable="false"
          @error="imgError = true"
        />
        <div v-else class="mv-broken">
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
          <span>Media unavailable</span>
        </div>
      </div>

      <!-- Top bar -->
      <div class="mv-topbar">
        <div class="mv-info">
          <span class="mv-title">{{ current?.title || '' }}</span>
          <span v-if="current?.subtitle" class="mv-subtitle">{{
            current.subtitle
          }}</span>
        </div>
        <div class="mv-counter">
          {{ currentIndex + 1 }} / {{ items.length }}
        </div>
        <div class="mv-top-actions">
          <template v-if="!current?.video">
            <button class="mv-btn" @click="zoomOut" title="Zoom out">
              <ZoomOut :size="18" />
            </button>
            <button class="mv-btn" @click="zoomIn" title="Zoom in">
              <ZoomIn :size="18" />
            </button>
          </template>
          <button
            v-if="current?.fullSrc && !current?.video"
            class="mv-btn"
            :class="{ 'mv-btn--active': showFull }"
            @click="showFull = !showFull"
            :title="showFull ? 'Back to fit size' : 'Load full resolution'"
          >
            <Maximize2 :size="18" />
          </button>
          <a
            v-if="current"
            class="mv-btn"
            :href="current.fullSrc || current.src"
            download
            target="_blank"
            title="Download original"
            ><Download :size="18"
          /></a>
          <router-link
            v-if="current"
            class="mv-btn"
            :to="`/photos/${current.id}`"
            title="Permalink"
            @click="emit('close')"
            ><ExternalLink :size="18"
          /></router-link>
          <button
            v-if="current?.meta && Object.keys(current.meta).length"
            class="mv-btn"
            :class="{ 'mv-btn--active': showInfo }"
            @click="showInfo = !showInfo"
            title="Info"
          >
            <Info :size="18" />
          </button>
          <button
            class="mv-btn mv-btn--danger"
            @click="handleDelete"
            title="Delete"
          >
            <Trash2 :size="18" />
          </button>
          <button class="mv-btn" @click="emit('close')" title="Close">
            <X :size="20" />
          </button>
        </div>
      </div>

      <!-- Nav arrows -->
      <button v-if="hasPrev" class="mv-arrow mv-arrow--left" @click="prev">
        <ChevronLeft :size="32" />
      </button>
      <button v-if="hasNext" class="mv-arrow mv-arrow--right" @click="next">
        <ChevronRight :size="32" />
      </button>

      <!-- Info panel -->
      <Transition name="mv-slide">
        <div v-if="showInfo && current?.meta" class="mv-info-panel">
          <div
            v-for="(value, key) in current.meta"
            :key="key"
            class="mv-info-row"
          >
            <span class="mv-info-label">{{ key }}</span>
            <span v-if="String(key) === 'Location'" class="mv-info-value">
              <a
                :href="`https://www.openstreetmap.org/?mlat=${String(value).split(', ')[0]}&mlon=${String(value).split(', ')[1]}#map=15/${String(value).split(', ')[0]}/${String(value).split(', ')[1]}`"
                target="_blank"
                rel="noopener"
                class="mv-info-link"
                >{{ value }}</a
              >
            </span>
            <span v-else class="mv-info-value">{{ value ?? '—' }}</span>
          </div>
        </div>
      </Transition>
    </div>
  </Teleport>
</template>

<style scoped>
.mv-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.92);
  z-index: 9999;
  display: flex;
  flex-direction: column;
}

.mv-topbar {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0.75rem 1rem;
  background: rgba(0, 0, 0, 0.4);
  z-index: 2;
}

.mv-info {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.mv-title {
  color: #fff;
  font-weight: 500;
  font-size: 0.9rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.mv-subtitle {
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.8rem;
}

.mv-counter {
  color: rgba(255, 255, 255, 0.5);
  font-size: 0.8rem;
  white-space: nowrap;
}

.mv-top-actions {
  display: flex;
  gap: 0.25rem;
}

.mv-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 8px;
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.7);
  cursor: pointer;
  transition:
    background 0.15s,
    color 0.15s;
  text-decoration: none;
  padding: 0;
}

.mv-btn:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}

.mv-btn--danger:hover {
  color: var(--danger);
}

.mv-stage {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  z-index: 1;
}

.mv-image {
  max-width: 90%;
  max-height: 100%;
  object-fit: contain;
  transition: transform 0.2s;
  user-select: none;
}

.mv-player {
  width: 90%;
  height: 92%;
  background: transparent;
}

.mv-broken {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.75rem;
  color: rgba(255, 255, 255, 0.3);
  font-size: 0.9rem;
}

.mv-arrow {
  position: fixed;
  top: 50%;
  transform: translateY(-50%);
  z-index: 3;
  background: rgba(255, 255, 255, 0.08);
  border: none;
  color: rgba(255, 255, 255, 0.7);
  cursor: pointer;
  padding: 0.75rem 0.5rem;
  border-radius: 10px;
  transition:
    background 0.15s,
    color 0.15s;
}

.mv-arrow:hover {
  background: rgba(255, 255, 255, 0.15);
  color: #fff;
}

.mv-arrow--left {
  left: 1rem;
}

.mv-arrow--right {
  right: 1rem;
}

.mv-btn--active {
  background: rgba(255, 255, 255, 0.15);
  color: #fff;
}

/* Info panel */
.mv-info-panel {
  position: fixed;
  right: 0;
  top: 0;
  bottom: 0;
  width: 280px;
  background: rgba(0, 0, 0, 0.85);
  backdrop-filter: blur(10px);
  border-left: 1px solid rgba(255, 255, 255, 0.1);
  z-index: 4;
  padding: 4rem 1.25rem 1.25rem;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
}

.mv-info-row {
  display: flex;
  flex-direction: column;
  padding: 0.5rem 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
}

.mv-info-label {
  font-size: 0.8rem;
  color: rgba(255, 255, 255, 0.4);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.mv-info-value {
  color: rgba(255, 255, 255, 0.9);
  font-size: 0.9rem;
  word-break: break-word;
}

.mv-info-link {
  color: var(--primary);
  text-decoration: none;
}

.mv-info-link:hover {
  text-decoration: underline;
}

/* Slide transition */
.mv-slide-enter-active,
.mv-slide-leave-active {
  transition: transform 0.2s ease;
}

.mv-slide-enter-from,
.mv-slide-leave-to {
  transform: translateX(100%);
}
</style>
