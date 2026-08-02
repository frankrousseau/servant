<script setup lang="ts">
import { computed, watch } from 'vue'
import { useRoute } from 'vue-router'

import AppSidebar from './components/AppSidebar.vue'
import CommandPalette from './components/CommandPalette.vue'
import ConfirmModal from './components/ConfirmModal.vue'

import { useAuthStore } from './stores/auth'
import { useAppsStore } from './stores/apps'

const auth = useAuthStore()
const apps = useAppsStore()
const route = useRoute()

// App routes are full-bleed: the apps lay out their own full-height chrome.
const flushContent = computed(() => route.name === 'app')

// Installed apps come from the API, so they can only load once authenticated;
// the sidebar shows builtins in the meantime. Loaded here rather than in a
// consumer: the sidebar, the palette, Settings and AppView all read the store.
watch(
  () => auth.isAuthenticated,
  authed => {
    if (authed) apps.load().catch(() => {})
  },
  { immediate: true }
)
</script>

<template>
  <div class="app-layout" :class="{ authenticated: auth.isAuthenticated }">
    <AppSidebar v-if="auth.isAuthenticated" />
    <main class="content" :class="{ 'content--flush': flushContent }">
      <router-view />
    </main>
    <ConfirmModal />
    <CommandPalette v-if="auth.isAuthenticated" />
  </div>
</template>
