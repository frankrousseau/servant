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

// The installed apps come from the API, so they can load only after the
// authentication. Until then, the sidebar shows the builtins. This component
// loads them, and not a consumer, because these all read the store:
// - the sidebar
// - the palette
// - Settings
// - AppView
// The loss of the session (expired cookie at boot, 401 in the middle of a
// session) clears the auth state outside all navigation. As a result, the
// router guard never runs. Send the user to the login page from here.
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
