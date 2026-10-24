<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'

import MediaViewer from '../components/MediaViewer.vue'

import { createAppContext } from '../apps/createContext'
import { useAppsStore } from '../stores/apps'
import type { AppModule, ViewerAPI, ViewerItem } from '../apps/types'

const route = useRoute()
const appsStore = useAppsStore()
const mountEl = ref<HTMLElement | null>(null)
const error = ref('')
let currentApp: AppModule | null = null

// Viewer state (shared with apps through the context)
const viewerItems = ref<ViewerItem[]>([])
const viewerIndex = ref(0)
const viewerOpen = ref(false)
let viewerDeleteCb: ((id: string) => void) | null = null
let viewerCloseCb: (() => void) | null = null
let viewerNoteCb: ((id: string, note: string) => void) | null = null

const viewerAPI: ViewerAPI = {
  open(items, startIndex = 0) {
    viewerItems.value = items
    viewerIndex.value = startIndex
    viewerOpen.value = true
  },
  close() {
    viewerOpen.value = false
  },
  onNote(cb) {
    viewerNoteCb = cb
  },
  onDelete(cb) {
    viewerDeleteCb = cb
  },
  onClose(cb) {
    viewerCloseCb = cb
  }
}

// Build the app context one time, here in setup(). createAppContext calls
// useRouter(), useAuthStore() and useConfirm(). These must run in the setup
// context of a component, not later inside the async loadApp() watch
// callback. There, the injection of useRouter can resolve to undefined after
// an await.
const ctx = createAppContext(viewerAPI)

function handleViewerClose() {
  viewerOpen.value = false
  if (viewerCloseCb) viewerCloseCb()
}

function handleViewerNote(id: string, note: string) {
  viewerItems.value = viewerItems.value.map(item =>
    item.id === id ? { ...item, note } : item
  )
  if (viewerNoteCb) viewerNoteCb(id, note)
}

function handleViewerDelete(id: string) {
  if (viewerDeleteCb) viewerDeleteCb(id)
  // Remove the item from the items and adjust the index.
  const idx = viewerItems.value.findIndex(item => item.id === id)
  if (idx >= 0) {
    viewerItems.value = viewerItems.value.filter(item => item.id !== id)
    if (viewerItems.value.length === 0) {
      viewerOpen.value = false
      if (viewerCloseCb) viewerCloseCb()
    } else if (viewerIndex.value >= viewerItems.value.length) {
      viewerIndex.value = viewerItems.value.length - 1
    }
  }
}

async function loadApp(appId: string) {
  if (currentApp?.unmount && mountEl.value) {
    currentApp.unmount(mountEl.value)
  }
  currentApp = null
  error.value = ''
  viewerOpen.value = false
  viewerDeleteCb = null
  viewerCloseCb = null
  viewerNoteCb = null

  // A direct navigation to an installed app can land here before the store
  // fetches the list. load() is a no-op when the list is already fetched.
  await appsStore.load().catch(() => {})

  const def = appsStore.getDef(appId)
  if (!def) {
    error.value = `App "${appId}" not found`
    return
  }

  try {
    const mod = await def.load()
    currentApp = mod.default
    if (mountEl.value) {
      await currentApp.mount(mountEl.value, ctx)
      document.title = `Servant | ${def.name}`
    }
  } catch (err: any) {
    error.value = err.message || 'Failed to load app'
  }
}

watch(
  () => route.params.appId as string,
  appId => {
    if (appId) loadApp(appId)
  },
  { immediate: true }
)

onUnmounted(() => {
  if (currentApp?.unmount && mountEl.value) {
    currentApp.unmount(mountEl.value)
  }
})
</script>

<template>
  <div class="app-host">
    <p v-if="error" class="app-error">{{ error }}</p>
    <div ref="mountEl" class="app-mount"></div>
    <MediaViewer
      v-if="viewerOpen && viewerItems.length"
      :items="viewerItems"
      :start-index="viewerIndex"
      @close="handleViewerClose"
      @delete="handleViewerDelete"
      @note="handleViewerNote"
    />
  </div>
</template>

<style scoped>
.app-host {
  height: 100%;
}

.app-error {
  color: var(--danger);
  padding: 2rem;
}

.app-mount {
  height: 100%;
}
</style>
