<script setup lang="ts">
import { ref, watch, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import { getAppDef } from '../apps/registry'
import { createAppContext } from '../apps/createContext'
import type { AppModule, ViewerItem, ViewerAPI } from '../apps/types'
import MediaViewer from '../components/MediaViewer.vue'

const route = useRoute()
const mountEl = ref<HTMLElement | null>(null)
const error = ref('')
let currentApp: AppModule | null = null

// Viewer state (shared with apps via context)
const viewerItems = ref<ViewerItem[]>([])
const viewerIndex = ref(0)
const viewerOpen = ref(false)
let viewerDeleteCb: ((id: string) => void) | null = null

const viewerAPI: ViewerAPI = {
  open(items, startIndex = 0) {
    viewerItems.value = items
    viewerIndex.value = startIndex
    viewerOpen.value = true
  },
  close() {
    viewerOpen.value = false
  },
  onDelete(cb) {
    viewerDeleteCb = cb
  }
}

// Build the app context once, here in setup(): createAppContext calls
// useRouter()/useAuthStore()/useConfirm(), which must run in a component's setup
// context, not later inside the async loadApp() watch callback (where
// useRouter's injection may resolve to undefined after an await).
const ctx = createAppContext(viewerAPI)

function handleViewerClose() {
  viewerOpen.value = false
}

function handleViewerDelete(id: string) {
  if (viewerDeleteCb) viewerDeleteCb(id)
  // Remove from items and adjust index
  const idx = viewerItems.value.findIndex(i => i.id === id)
  if (idx >= 0) {
    viewerItems.value = viewerItems.value.filter(i => i.id !== id)
    if (viewerItems.value.length === 0) {
      viewerOpen.value = false
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

  const def = getAppDef(appId)
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
  } catch (e: any) {
    error.value = e.message || 'Failed to load app'
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
    />
  </div>
</template>

<style scoped>
.app-host {
  height: 100%;
}

.app-mount {
  height: 100%;
}

.app-error {
  color: var(--danger);
  padding: 2rem;
}
</style>
