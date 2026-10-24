<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import { Cable, LayoutGrid, Search, Upload } from 'lucide-vue-next'

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

// In drawer mode (below the tablet breakpoint) the nav slides in over the
// page from the top bar's toggle; closed, it is inert so neither the tab
// order nor assistive tech can reach links that are off screen.
const props = defineProps<{ drawer: boolean; open: boolean }>()
const emit = defineEmits<{ close: [] }>()

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
// page has arrow buttons for the keyboard and touch screens)
const {
  draggingId,
  marks,
  onDragStart,
  onDragOver,
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
    :class="{ 'sidebar--drawer': drawer, 'sidebar--open': drawer && open }"
    aria-label="Main"
    :inert="hidden"
    @keydown.escape="emit('close')"
  >
    <div class="sidebar-head">
      <router-link to="/" class="sidebar-brand">
        <BrandMark :size="26" />
        Servant
      </router-link>
      <!-- The phone top bar has its own search button -->
      <button
        v-if="!drawer"
        type="button"
        class="sidebar-search"
        aria-label="Search"
        aria-keyshortcuts="Control+K Meta+K"
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
    <ul class="sidebar-nav" @dragleave="onDragLeave">
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
          draggable="true"
          @dragstart="onDragStart(app.id, $event)"
          @dragend="onDragEnd"
        >
          <component :is="app.icon" :size="18" />{{ app.name }}
        </router-link>
      </li>
      <li>
        <router-link
          to="/apps"
          class="sidebar-all"
          :class="{ 'sidebar-all--current': inUnpinnedApp }"
          :aria-label="allAppsLabel"
        >
          <LayoutGrid :size="18" />All apps
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
    >
      <Upload :size="14" />photos
      {{
        photosProgress ? `${photosProgress.index}/${photosProgress.total}` : ''
      }}
    </router-link>
    <router-link
      v-if="filesUploading"
      to="/apps/files"
      class="sidebar-upload"
      title="File upload in progress"
    >
      <Upload :size="14" />files
      {{ filesProgress ? `${filesProgress.index}/${filesProgress.total}` : '' }}
    </router-link>
    <router-link to="/connectors" class="sidebar-settings-link">
      <Cable :size="18" />Sources
    </router-link>
    <AccountMenu />
  </nav>
</template>

<style scoped>
/* ----- Layout ----- */

/* Moved here with the markup. `:deep(svg)` below finally applies: the
   rule lived in the global sheet, where that Vue-only selector is
   invalid, so lucide icons could shrink under a long app name. */
.sidebar {
  position: fixed;
  top: 0;
  left: 0;
  width: var(--sidebar-width);
  height: 100vh;
  background: var(--bg-surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  padding-top: 1rem;
  overflow-y: auto;
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

/* ----- Brand and search ----- */

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
  font-size: 1.5rem;
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

/* Below the icon, right-aligned: the sidebar scrolls, so a tip poking
   past its right edge would be clipped. */
.sidebar-search-tip {
  position: absolute;
  top: calc(100% + 0.35rem);
  right: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.3rem 0.6rem;
  white-space: nowrap;
  background: var(--bg-hover);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text);
  font-size: 0.875rem;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.15s;
}

.sidebar-search:hover .sidebar-search-tip,
.sidebar-search:focus-visible .sidebar-search-tip {
  opacity: 1;
}

.sidebar-search-tip kbd {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.875rem;
}

/* ----- Apps ----- */

.sidebar-nav {
  list-style: none;
  flex: 1;
}

.sidebar-nav li a {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  padding: 0.6rem 1.25rem;
  color: var(--text-muted);
  font-size: 1rem;
  text-decoration: none;
  transition:
    background 0.15s,
    color 0.15s;
}

.sidebar-nav li a :deep(svg) {
  flex-shrink: 0;
}

.sidebar-nav li a:hover {
  color: var(--text);
}

/* vue-router stamps aria-current="page" on the exact active link; styling
   the attribute keeps the announced and visible states in sync. */
.sidebar-nav li a[aria-current='page'] {
  color: var(--text);
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

.sidebar-nav li a.sidebar-all--current {
  color: var(--text);
}

.sidebar-count {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 0.875rem;
}

/* ----- Uploads and Sources ----- */

/* Global photo-upload pulse: the queue keeps running across app switches */
.sidebar-upload {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  padding: 0.45rem 1.25rem;
  color: var(--primary);
  text-decoration: none;
  font-family: var(--font-mono);
  font-size: 0.78rem;
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

.sidebar-settings-link {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  color: var(--text-muted);
  text-decoration: none;
  font-size: 1rem;
  padding: 0.6rem 1.25rem;
  transition: color 0.15s;
}

/* aria-current covers the exact page; .router-link-active stays for the
   ancestor case, it keeps Sources lit on a child page (/connectors/:id). */
.sidebar-settings-link:hover,
.sidebar-settings-link[aria-current='page'],
.sidebar-settings-link.router-link-active {
  color: var(--text);
  text-decoration: none;
}
</style>
