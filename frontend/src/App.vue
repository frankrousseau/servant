<script setup lang="ts">
import { computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'

import AppSidebar from './components/AppSidebar.vue'
import CommandPalette from './components/CommandPalette.vue'
import ConfirmModal from './components/ConfirmModal.vue'

import { useAppsStore } from './stores/apps'
import { useAuthStore } from './stores/auth'

const auth = useAuthStore()
const apps = useAppsStore()
const route = useRoute()
const router = useRouter()

// App routes are full-bleed: the apps lay out their own full-height chrome.
const flushContent = computed(() => route.name === 'app')
// Public pages (a shared photo feed) render without the shell, even for a
// logged-in owner: what they see is what a visitor gets.
const publicPage = computed(() => route.meta.public === true)

// Installed apps come from the API, so they can only load once authenticated;
// the sidebar shows builtins in the meantime. Loaded here rather than in a
// consumer: the sidebar, the palette, Settings and AppView all read the store.
// Losing the session (expired cookie at boot, 401 mid-session) clears the auth
// state outside any navigation, so the router guard never runs: send the user
// to the login page from here.
watch(
  () => auth.isAuthenticated,
  authed => {
    if (authed) apps.load().catch(() => {})
    else if (route.meta.auth) router.replace({ name: 'login' })
  },
  { immediate: true }
)
</script>

<template>
  <div
    class="app-layout"
    :class="{ authenticated: auth.isAuthenticated && !publicPage }"
  >
    <AppSidebar v-if="auth.isAuthenticated && !publicPage" />
    <main class="content" :class="{ 'content--flush': flushContent }">
      <router-view />
    </main>
    <ConfirmModal />
    <CommandPalette v-if="auth.isAuthenticated && !publicPage" />
  </div>
</template>
