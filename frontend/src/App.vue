<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useMediaQuery } from '@vueuse/core'

import AppSidebar from './components/AppSidebar.vue'
import AppTopbar from './components/AppTopbar.vue'
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
const shell = computed(() => auth.isAuthenticated && !publicPage.value)

// Same breakpoint as the --topbar-height switch in style.css: below it the
// sidebar becomes a drawer opened from the top bar.
const compact = useMediaQuery('(max-width: 1024px)')
const navOpen = ref(false)

// Following a link from the drawer is the end of the trip: close it. The
// drawer also folds away when the window grows back past the breakpoint.
watch(() => route.fullPath, closeNav)
watch(compact, closeNav)

function closeNav() {
  navOpen.value = false
}

// The drawer is inert while closed, so a keyboard user opening it lands on
// its first link; closing it hands the focus back to the toggle.
async function toggleNav() {
  navOpen.value = !navOpen.value
  await nextTick()
  const target = navOpen.value
    ? '#app-sidebar a'
    : '[aria-controls="app-sidebar"]'
  document.querySelector<HTMLElement>(target)?.focus()
}

// Escape or a tap on the backdrop: close and hand the focus back
function onDrawerClose() {
  if (navOpen.value) void toggleNav()
}

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
  <div class="app-layout" :class="{ authenticated: shell }">
    <AppTopbar
      v-if="shell && compact"
      :nav-open="navOpen"
      @toggle-nav="toggleNav"
    />
    <AppSidebar
      v-if="shell"
      :drawer="compact"
      :open="navOpen"
      @close="onDrawerClose"
    />
    <main class="content" :class="{ 'content--flush': flushContent }">
      <router-view />
    </main>
    <ConfirmModal />
    <CommandPalette v-if="shell" />
  </div>
</template>
