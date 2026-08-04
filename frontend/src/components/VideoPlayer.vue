<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import {
  Maximize,
  Minimize,
  Pause,
  Play,
  Volume2,
  VolumeX
} from 'lucide-vue-next'

import { formatDuration } from '../lib/datetime'

const props = defineProps<{ src: string; autoplay?: boolean }>()
const emit = defineEmits<{ error: [] }>()

const root = ref<HTMLElement | null>(null)
const video = ref<HTMLVideoElement | null>(null)
const bar = ref<HTMLElement | null>(null)

const playing = ref(false)
const currentTime = ref(0)
const duration = ref(0)
const bufferedEnd = ref(0)
const volume = ref(1)
const muted = ref(false)
const fullscreen = ref(false)
const controlsVisible = ref(true)
const scrubbing = ref(false)

const playedPct = computed(() =>
  duration.value ? (currentTime.value / duration.value) * 100 : 0
)
const bufferedPct = computed(() =>
  duration.value ? (bufferedEnd.value / duration.value) * 100 : 0
)
const timeLabel = computed(
  () =>
    `${formatDuration(currentTime.value)} / ${formatDuration(duration.value)}`
)
const idle = computed(() => playing.value && !controlsVisible.value)

function togglePlay() {
  const media = video.value
  if (!media) return
  if (media.paused) void media.play()
  else media.pause()
  wake()
}

// `timeupdate` only fires ~4x/s; drive the seekbar with rAF while playing so
// it moves smoothly. The event stays as the paused-state fallback (seeks).
let rafId: number | undefined
function tick() {
  if (!scrubbing.value) currentTime.value = video.value?.currentTime || 0
  rafId = requestAnimationFrame(tick)
}
function onPlay() {
  playing.value = true
  startTicking()
  wake()
}

function onPause() {
  playing.value = false
  stopTicking()
  wake()
}

function onEnded() {
  playing.value = false
  stopTicking()
  controlsVisible.value = true
}

function startTicking() {
  if (rafId === undefined) rafId = requestAnimationFrame(tick)
}
function stopTicking() {
  if (rafId !== undefined) {
    cancelAnimationFrame(rafId)
    rafId = undefined
  }
}

function onTimeUpdate() {
  if (!scrubbing.value) currentTime.value = video.value?.currentTime || 0
}
function onLoadedMetadata() {
  const seconds = video.value?.duration || 0
  duration.value = Number.isFinite(seconds) ? seconds : 0
}
function onProgress() {
  const media = video.value
  if (media && media.buffered.length)
    bufferedEnd.value = media.buffered.end(media.buffered.length - 1)
}
function onVolumeChange() {
  const media = video.value
  if (!media) return
  volume.value = media.volume
  muted.value = media.muted
}

// YouTube-style auto-hide: controls fade out after inactivity while playing,
// and immediately when the pointer leaves the player.
let hideTimer: ReturnType<typeof setTimeout> | undefined
function wake() {
  controlsVisible.value = true
  if (hideTimer) clearTimeout(hideTimer)
  hideTimer = setTimeout(() => {
    if (playing.value && !scrubbing.value) controlsVisible.value = false
  }, 2500)
}
function onMouseLeave() {
  if (hideTimer) clearTimeout(hideTimer)
  if (playing.value && !scrubbing.value) controlsVisible.value = false
}

// ----- seekbar scrubbing (click or drag anywhere on the bar) -----

function barFraction(event: PointerEvent): number {
  const rect = bar.value!.getBoundingClientRect()
  return Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1)
}
function startScrub(event: PointerEvent) {
  if (!video.value || !duration.value) return
  scrubbing.value = true
  ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
  currentTime.value = barFraction(event) * duration.value
}
function moveScrub(event: PointerEvent) {
  if (scrubbing.value) currentTime.value = barFraction(event) * duration.value
}
function endScrub(event: PointerEvent) {
  if (!scrubbing.value) return
  scrubbing.value = false
  if (video.value) video.value.currentTime = barFraction(event) * duration.value
  wake()
}

// ----- volume / fullscreen -----

function toggleMute() {
  const media = video.value
  if (media) media.muted = !media.muted
}
function onVolumeInput(event: Event) {
  const media = video.value
  if (!media) return
  media.volume = parseFloat((event.target as HTMLInputElement).value)
  media.muted = media.volume === 0
}
function toggleFullscreen() {
  if (document.fullscreenElement) void document.exitFullscreen()
  else void root.value?.requestFullscreen()
}
function onFsChange() {
  fullscreen.value = !!document.fullscreenElement
}

// Space / K toggle playback (unless typing somewhere).
function onKeydown(event: KeyboardEvent) {
  if (event.key !== ' ' && event.key !== 'k') return
  const target = event.target as HTMLElement
  if (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target.isContentEditable
  )
    return
  event.preventDefault()
  togglePlay()
}

onMounted(() => {
  document.addEventListener('fullscreenchange', onFsChange)
  document.addEventListener('keydown', onKeydown)
  wake()
})
onUnmounted(() => {
  document.removeEventListener('fullscreenchange', onFsChange)
  document.removeEventListener('keydown', onKeydown)
  if (hideTimer) clearTimeout(hideTimer)
  stopTicking()
})
</script>

<template>
  <div
    ref="root"
    class="vp"
    :class="{ 'vp--idle': idle }"
    @mousemove="wake"
    @mouseleave="onMouseLeave"
  >
    <video
      ref="video"
      class="vp-video"
      :src="src"
      :autoplay="autoplay"
      playsinline
      @click="togglePlay"
      @dblclick="toggleFullscreen"
      @play="onPlay"
      @pause="onPause"
      @ended="onEnded"
      @timeupdate="onTimeUpdate"
      @loadedmetadata="onLoadedMetadata"
      @progress="onProgress"
      @volumechange="onVolumeChange"
      @error="emit('error')"
    ></video>

    <button
      v-if="!playing"
      class="vp-bigplay"
      aria-label="Play"
      @click="togglePlay"
    >
      <Play :size="30" fill="currentColor" />
    </button>

    <div class="vp-controls" @click.stop @dblclick.stop>
      <div
        ref="bar"
        class="vp-seek"
        :class="{ 'vp-seek--active': scrubbing }"
        @pointerdown="startScrub"
        @pointermove="moveScrub"
        @pointerup="endScrub"
        @pointercancel="endScrub"
      >
        <div class="vp-seek-bg"></div>
        <div
          class="vp-seek-buffered"
          :style="{ width: bufferedPct + '%' }"
        ></div>
        <div class="vp-seek-played" :style="{ width: playedPct + '%' }">
          <div class="vp-knob"></div>
        </div>
      </div>
      <div class="vp-row">
        <button
          class="vp-btn"
          :title="playing ? 'Pause' : 'Play'"
          @click="togglePlay"
        >
          <Pause v-if="playing" :size="20" /><Play v-else :size="20" />
        </button>
        <button
          class="vp-btn"
          :title="muted ? 'Unmute' : 'Mute'"
          @click="toggleMute"
        >
          <VolumeX v-if="muted || volume === 0" :size="20" /><Volume2
            v-else
            :size="20"
          />
        </button>
        <input
          class="vp-volume"
          type="range"
          min="0"
          max="1"
          step="0.05"
          :value="muted ? 0 : volume"
          @input="onVolumeInput"
        />
        <span class="vp-time">{{ timeLabel }}</span>
        <span class="vp-spacer"></span>
        <button
          class="vp-btn"
          :title="fullscreen ? 'Exit full screen' : 'Full screen'"
          @click="toggleFullscreen"
        >
          <Minimize v-if="fullscreen" :size="20" /><Maximize
            v-else
            :size="20"
          />
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.vp {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #000;
  overflow: hidden;
}
.vp--idle {
  cursor: none;
}
.vp-video {
  width: 100%;
  height: 100%;
  object-fit: contain;
  display: block;
}
.vp-bigplay {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 64px;
  height: 64px;
  border-radius: 50%;
  border: none;
  background: rgba(0, 0, 0, 0.6);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  padding: 0 0 0 4px;
}
.vp-bigplay:hover {
  background: rgba(var(--primary-rgb), 0.85);
}
.vp-controls {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  padding: 1rem 0.75rem 0.35rem;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.8));
  /* Fade back in quickly… */
  transition: opacity 0.15s ease-out;
}
.vp--idle .vp-controls {
  opacity: 0;
  pointer-events: none;
  /* …but fade out slowly (the rule of the state being entered wins). */
  transition: opacity 0.5s ease;
}
.vp-seek {
  position: relative;
  height: 14px;
  display: flex;
  align-items: center;
  cursor: pointer;
  touch-action: none;
}
.vp-seek-bg,
.vp-seek-buffered,
.vp-seek-played {
  position: absolute;
  height: 3px;
  border-radius: 2px;
  transition: height 0.1s;
  pointer-events: none;
}
.vp-seek-bg {
  left: 0;
  right: 0;
  background: rgba(255, 255, 255, 0.25);
}
.vp-seek-buffered {
  background: rgba(255, 255, 255, 0.45);
}
.vp-seek-played {
  background: var(--primary);
  display: flex;
  align-items: center;
  justify-content: flex-end;
}
.vp-seek:hover .vp-seek-bg,
.vp-seek:hover .vp-seek-buffered,
.vp-seek:hover .vp-seek-played,
.vp-seek--active .vp-seek-bg,
.vp-seek--active .vp-seek-buffered,
.vp-seek--active .vp-seek-played {
  height: 5px;
}
.vp-knob {
  width: 13px;
  height: 13px;
  border-radius: 50%;
  background: var(--primary);
  margin-right: -6px;
  transform: scale(0);
  transition: transform 0.1s;
}
.vp-seek:hover .vp-knob,
.vp-seek--active .vp-knob {
  transform: scale(1);
}
.vp-row {
  display: flex;
  align-items: center;
  gap: 0.25rem;
}
.vp-btn {
  width: 36px;
  height: 36px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: transparent;
  border: none;
  border-radius: 6px;
  color: #fff;
  opacity: 0.85;
  cursor: pointer;
  padding: 0;
}
.vp-btn:hover {
  opacity: 1;
  background: rgba(255, 255, 255, 0.12);
}
.vp-volume {
  width: 70px;
  padding: 0;
  background: transparent;
  border: none;
  accent-color: #fff;
  cursor: pointer;
}
.vp-time {
  color: rgba(255, 255, 255, 0.9);
  font-size: 0.8rem;
  margin-left: 0.5rem;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
.vp-spacer {
  flex: 1;
}
</style>
