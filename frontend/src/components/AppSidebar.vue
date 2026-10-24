<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import {
  Cable,
  LayoutGrid,
  PanelLeftClose,
  PanelLeftOpen,
  Search,
  Upload,
  X
} from 'lucide-vue-next'

import AccountMenu from './AccountMenu.vue'
import BrandMark from './BrandMark.vue'

import {
  uploadProgress as filesProgress,
  uploading as filesUploading
} from '../apps/files/uploadQueue'
import {
  uploadProgress as photosProgress,
  uploading as photosUploading
} from '../apps/photos/uploadQueue'
import { useCommandPalette } from '../composables/useCommandPalette'
import { useDragReorder } from '../composables/useDragReorder'
import { appIcon } from '../lib/appIcons'
import { useAppsStore } from '../stores/apps'

import type { UploadProgress } from '../lib/uploadQueue'

// In drawer mode (below the tablet breakpoint) the nav slides in over the
// page from the top bar's toggle; closed, it is inert so neither the tab
// order nor assistive tech can reach links that are off screen. Above it,
// `collapsed` folds the sidebar to a rail of icons (App.vue keeps the
// choice); the drawer always has room for the names.
const props = defineProps<{
  drawer: boolean
  open: boolean
  collapsed: boolean
}>()
const emit = defineEmits<{ close: []; toggleCollapsed: [] }>()

const hidden = computed(() => props.drawer && !props.open)

const apps = useAppsStore()
const palette = useCommandPalette()
const route = useRoute()

const pinnedLinks = computed(() =>
  apps.pinned.map(app => ({
    id: app.id,
    name: app.name,
    icon: appIcon(app.icon)
  }))
)

// Drag a pinned app to reorder the sidebar in place (mouse only; the Apps
// page has arrow buttons for the keyboard and touch screens). All apps,
// right after the last pinned app, drops at the end.
const {
  draggingId,
  marks,
  onDragStart,
  onDragOver,
  onDragOverEnd,
  onDragLeave,
  onDrop,
  onDragEnd
} = useDragReorder(
  () => apps.pinned.map(app => app.id),
  (id, toIndex) => apps.placePinned(id, toIndex)
)

const shortcut = /Mac|iPhone|iPad/.test(navigator.userAgent) ? '⌘ K' : 'Ctrl K'

// An app opened from the launcher has no row of its own here: light
// "All apps" instead, so the sidebar still shows where the user is.
const inUnpinnedApp = computed(
  () =>
    route.name === 'app' &&
    apps.unpinned.some(app => app.id === route.params.appId)
)

const allAppsLabel = computed(() =>
  apps.unpinned.length
    ? `All apps, ${apps.unpinned.length} not in the sidebar`
    : 'All apps'
)

// "3/10" while an upload queue reports its progress
function progressText(progress: UploadProgress | null) {
  return progress ? `${progress.index}/${progress.total}` : ''
}

const photosCount = computed(() => progressText(photosProgress.value))
const filesCount = computed(() => progressText(filesProgress.value))

// Folded to a rail, the sidebar names each icon in a tip beside it, on
// hover and on keyboard focus. The names stay in the DOM for assistive
// tech, so the tip is only visual. One tip for the whole nav, fixed to the
// viewport: the app list scrolls, and a tip inside it would be clipped.
interface Tip {
  label: string
  kbd?: string
  top: number
  left: number
}

const tip = ref<Tip | null>(null)

const tipStyle = computed(() =>
  tip.value ? { top: `${tip.value.top}px`, left: `${tip.value.left}px` } : {}
)

function showTip(event: Event) {
  if (!props.collapsed) return
  const target = (event.target as Element | null)?.closest<HTMLElement>(
    '[data-tip]'
  )
  if (!target) return
  // Level with the icon, in one column past the rail's edge
  const box = target.getBoundingClientRect()
  const rail = (event.currentTarget as HTMLElement).getBoundingClientRect()
  tip.value = {
    label: target.dataset.tip ?? '',
    kbd: target.dataset.tipKbd,
    top: box.top + box.height / 2,
    left: rail.right + 8
  }
}

function hideTip() {
  tip.value = null
}

// The toggle itself is under the pointer when the rail unfolds
watch(() => props.collapsed, hideTip)

function onEscape() {
  hideTip()
  emit('close')
}

function startDrag(id: string, event: DragEvent) {
  hideTip()
  onDragStart(id, event)
}
</script>

<template>
  <div
    v-if="drawer && open"
    class="sidebar-backdrop"
    aria-hidden="true"
    @click="emit('close')"
  ></div>
  <nav
    id="app-sidebar"
    class="sidebar"
    :class="{
      'sidebar--drawer': drawer,
      'sidebar--open': drawer && open,
      'sidebar--rail': collapsed
    }"
    aria-label="Main"
    :inert="hidden"
    @keydown.escape="onEscape"
    @pointerover="showTip"
    @pointerout="hideTip"
    @focusin="showTip"
    @focusout="hideTip"
  >
    <div class="sidebar-head">
      <router-link to="/" class="sidebar-brand" data-tip="Dashboard">
        <BrandMark :size="26" />
        <span class="sidebar-label">Servant</span>
      </router-link>
      <!-- The phone top bar has its own search button. Its menu toggle is
           under the open drawer, so the drawer brings a close button. -->
      <button
        v-if="drawer"
        type="button"
        class="sidebar-close"
        aria-label="Close menu"
        @click="emit('close')"
      >
        <X :size="20" />
      </button>
      <button
        v-else
        type="button"
        class="sidebar-search"
        aria-label="Search"
        aria-keyshortcuts="Control+K Meta+K"
        data-tip="Search"
        :data-tip-kbd="shortcut"
        @click="palette.toggle()"
      >
        <Search :size="18" />
        <span class="sidebar-search-tip" aria-hidden="true"
          >Search <kbd>{{ shortcut }}</kbd></span
        >
      </button>
    </div>
    <!-- The pinned apps (Apps page), then the way to all of them. The
         brand logo already lands on the dashboard; the rarely visited
         pages wait behind the account menu. -->
    <ul class="sidebar-nav" @dragleave="onDragLeave" @scroll="hideTip">
      <li
        v-for="(app, i) in pinnedLinks"
        :key="app.id"
        :class="{
          'sidebar-app--dragging': draggingId === app.id,
          'sidebar-app--before': marks[app.id] === 'before',
          'sidebar-app--after': marks[app.id] === 'after'
        }"
        @dragover="onDragOver(i, $event)"
        @drop="onDrop"
      >
        <router-link
          :to="`/apps/${app.id}`"
          :data-tip="app.name"
          draggable="true"
          @dragstart="startDrag(app.id, $event)"
          @dragend="onDragEnd"
        >
          <component :is="app.icon" :size="18" />
          <span class="sidebar-label">{{ app.name }}</span>
        </router-link>
      </li>
      <li @dragover="onDragOverEnd" @drop="onDrop">
        <router-link
          to="/apps"
          class="sidebar-all"
          :class="{ 'sidebar-all--current': inUnpinnedApp }"
          :aria-label="allAppsLabel"
          :data-tip="allAppsLabel"
        >
          <LayoutGrid :size="18" />
          <span class="sidebar-label">All apps</span>
          <span v-if="apps.unpinned.length" class="sidebar-count"
            >+{{ apps.unpinned.length }}</span
          >
        </router-link>
      </li>
    </ul>
    <router-link
      v-if="photosUploading"
      to="/apps/photos"
      class="sidebar-upload"
      title="Photo upload in progress"
      :data-tip="`Photo upload ${photosCount}`"
    >
      <Upload :size="16" />
      <span class="sidebar-label">photos {{ photosCount }}</span>
    </router-link>
    <router-link
      v-if="filesUploading"
      to="/apps/files"
      class="sidebar-upload"
      title="File upload in progress"
      :data-tip="`File upload ${filesCount}`"
    >
      <Upload :size="16" />
      <span class="sidebar-label">files {{ filesCount }}</span>
    </router-link>
    <router-link to="/connectors" class="sidebar-row" data-tip="Sources">
      <Cable :size="18" />
      <span class="sidebar-label">Sources</span>
    </router-link>
    <button
      v-if="!drawer"
      type="button"
      class="sidebar-row sidebar-collapse"
      :aria-label="collapsed ? 'Expand sidebar' : 'Collapse sidebar'"
      data-tip="Expand sidebar"
      @click="emit('toggleCollapsed')"
    >
      <PanelLeftOpen v-if="collapsed" :size="18" />
      <PanelLeftClose v-else :size="18" />
      <span class="sidebar-label">Collapse</span>
    </button>
    <AccountMenu :rail="collapsed" />
    <span v-if="tip" class="sidebar-tip" :style="tipStyle" aria-hidden="true"
      >{{ tip.label }}<kbd v-if="tip.kbd">{{ tip.kbd }}</kbd></span
    >
  </nav>
</template>

<style scoped>
/* ----- Layout ----- */

/* Only the app list scrolls (.sidebar-nav): the brand, Sources and the
   account stay in place, and the account menu and the rail's tips can
   reach past the sidebar's right edge. Above the page content, which the
   account menu covers when the sidebar is a rail. */
.sidebar {
  position: fixed;
  top: 0;
  left: 0;
  z-index: 20;
  width: var(--sidebar-width);
  height: 100vh;
  background: var(--bg-surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  padding-top: 1rem;
}

/* Off-canvas below the tablet breakpoint: parked left of the viewport,
   slid in over the content (and the top bar) when open. */
.sidebar--drawer {
  z-index: 40;
  height: 100dvh;
  width: min(280px, 85vw);
  transform: translateX(-100%);
  transition: transform 0.2s ease-out;
  padding-bottom: env(safe-area-inset-bottom);
}

.sidebar--open {
  transform: none;
  box-shadow: 0 0 40px rgba(0, 0, 0, 0.5);
}

.sidebar-backdrop {
  position: fixed;
  inset: 0;
  z-index: 35;
  background: rgba(0, 0, 0, 0.55);
}

/* ----- Brand, search and close ----- */

.sidebar-head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 1.25rem 1.25rem;
}

/* Owl-butler logo + wordmark, links back to the dashboard */
.sidebar-brand {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  font-family: var(--font-display);
  font-size: var(--text-xl);
  font-weight: 400;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(var(--primary-rgb), 0.55);
}

.sidebar-brand svg {
  flex-shrink: 0;
  filter: drop-shadow(0 0 6px rgba(var(--primary-rgb), 0.45));
}

/* Opens the command palette (a modal): an icon by the brand, its label in
   a tip on hover and on keyboard focus, which also teaches Ctrl+K. */
.sidebar-search {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 36px;
  height: 36px;
  /* Pushed to the right, the icon itself (not its 36px hit area) on the
     same 1.25rem padding as the rows below: (36 - 18) / 2 = 9px */
  margin-left: auto;
  margin-right: -9px;
  padding: 0;
  background: transparent;
  color: var(--text-muted);
  transition: color 0.15s;
}

.sidebar-search:hover {
  background: transparent;
  color: var(--text);
}

/* Shared by the search tip and the rail's tip */
.sidebar-search-tip,
.sidebar-tip {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.3rem 0.6rem;
  white-space: nowrap;
  background: var(--bg-raised);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text);
  font-size: var(--text-sm);
  pointer-events: none;
}

.sidebar-search-tip kbd,
.sidebar-tip kbd {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

/* Below the icon, right-aligned: a tip poking past the sidebar's right
   edge would sit over the page title. */
.sidebar-search-tip {
  position: absolute;
  top: calc(100% + 0.35rem);
  right: 0;
  z-index: 10;
  opacity: 0;
  transition: opacity 0.15s;
}

.sidebar-search:hover .sidebar-search-tip,
.sidebar-search:focus-visible .sidebar-search-tip {
  opacity: 1;
}

/* 44px square (the drawer is the touch layout), the icon on the rows'
   1.25rem padding: (44 - 20) / 2 = 12px */
.sidebar-close {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 44px;
  height: 44px;
  margin-left: auto;
  margin-right: -12px;
  padding: 0;
  background: transparent;
  color: var(--text-muted);
  transition: color 0.15s;
}

.sidebar-close:hover {
  background: transparent;
  color: var(--text);
}

/* ----- Apps ----- */

.sidebar-nav {
  list-style: none;
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

.sidebar-nav li a {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  padding: 0.6rem 1.25rem;
  color: var(--text-muted);
  font-size: var(--text-base);
  text-decoration: none;
  transition: color 0.15s;
}

.sidebar-nav li a :deep(svg) {
  flex-shrink: 0;
}

/* Inside the ring: the list scrolls, so an outer ring would be clipped */
.sidebar-nav li a:focus-visible {
  outline-offset: -2px;
}

.sidebar-nav li a:hover {
  color: var(--text);
}

/* vue-router stamps aria-current="page" on the exact active link; styling
   the attribute keeps the announced and visible states in sync. The icon
   takes the primary color: on the rail it is all that is left to see. */
.sidebar-nav li a[aria-current='page'],
.sidebar-nav li a.sidebar-all--current {
  color: var(--text);
}

.sidebar-nav li a[aria-current='page'] :deep(svg),
.sidebar-nav li a.sidebar-all--current :deep(svg) {
  color: var(--primary);
}

/* Drag to reorder: the dragged row fades, a primary line marks the gap
   it would drop into */
.sidebar-app--dragging {
  opacity: 0.4;
}

.sidebar-app--before {
  box-shadow: inset 0 2px 0 var(--primary);
}

.sidebar-app--after {
  box-shadow: inset 0 -2px 0 var(--primary);
}

.sidebar-count {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

/* ----- Uploads, Sources and the collapse toggle ----- */

/* Global photo-upload pulse: the queue keeps running across app switches */
.sidebar-upload {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.45rem 1.25rem;
  color: var(--primary);
  text-decoration: none;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  text-transform: uppercase;
  letter-spacing: 0.06em;
  animation: sidebar-upload-pulse 1.6s ease-in-out infinite;
}

.sidebar-upload:hover {
  text-decoration: none;
  color: var(--primary);
}

@keyframes sidebar-upload-pulse {
  50% {
    opacity: 0.45;
  }
}

.sidebar-row {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  width: 100%;
  padding: 0.6rem 1.25rem;
  color: var(--text-muted);
  text-decoration: none;
  font-size: var(--text-base);
  transition: color 0.15s;
}

/* aria-current covers the exact page; .router-link-active stays for the
   ancestor case, it keeps Sources lit on a child page (/connectors/:id). */
.sidebar-row:hover,
.sidebar-row[aria-current='page'],
.sidebar-row.router-link-active {
  color: var(--text);
  text-decoration: none;
}

.sidebar-row[aria-current='page'] :deep(svg),
.sidebar-row.router-link-active :deep(svg) {
  color: var(--primary);
}

/* A row like Sources, without the global button paint */
.sidebar-collapse {
  background: none;
  border: none;
  border-radius: 0;
  line-height: inherit;
  text-align: left;
}

.sidebar-collapse:hover {
  background: none;
}

/* ----- Rail ----- */

/* Folded to its icons: the names leave the screen but stay in the DOM,
   so every link keeps its accessible name; the tip shows them on hover
   and focus. */
.sidebar--rail .sidebar-label {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
  white-space: nowrap;
}

.sidebar--rail .sidebar-head {
  flex-direction: column;
  padding: 0.5rem 0 1rem;
}

.sidebar--rail .sidebar-search {
  margin: 0;
}

.sidebar--rail .sidebar-search-tip,
.sidebar--rail .sidebar-count {
  display: none;
}

.sidebar--rail .sidebar-nav li a,
.sidebar--rail .sidebar-upload,
.sidebar--rail .sidebar-row {
  justify-content: center;
  padding-inline: 0;
}

/* Beside the hovered or focused icon (coordinates from showTip) */
.sidebar-tip {
  position: fixed;
  z-index: 10;
  transform: translateY(-50%);
}
</style>
