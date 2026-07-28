<script setup lang="ts">
import { computed, watch } from 'vue'
import { useAuthStore } from './stores/auth'
import { useAppsStore } from './stores/apps'
import { agentsEnabled } from './apps/registry'
import { useRouter } from 'vue-router'
import {
  Database,
  Cable,
  Settings,
  LogOut,
  CircleUserRound,
  UserRound,
  CalendarDays,
  FolderOpen,
  Image,
  NotebookPen,
  ListChecks,
  Activity,
  Wallet,
  Target,
  Puzzle,
  Wrench
} from 'lucide-vue-next'
import {
  uploading as photosUploading,
  uploadProgress as photosProgress
} from './apps/photos/uploadQueue'
import {
  uploading as filesUploading,
  uploadProgress as filesProgress
} from './apps/files/uploadQueue'
import CommandPalette from './components/CommandPalette.vue'
import ConfirmModal from './components/ConfirmModal.vue'

const appIcons: Record<string, unknown> = {
  UserRound,
  CalendarDays,
  FolderOpen,
  Image,
  NotebookPen,
  ListChecks,
  Wallet,
  Target
}

const auth = useAuthStore()
const apps = useAppsStore()
const router = useRouter()

const showAgents = computed(() => agentsEnabled(auth.user?.enabled_apps))

// Installed apps come from the API, so they can only load once authenticated;
// the sidebar shows builtins in the meantime.
watch(
  () => auth.isAuthenticated,
  authed => {
    if (authed) apps.load().catch(() => {})
  },
  { immediate: true }
)

function handleLogout() {
  auth.logout()
  router.push('/login')
}
</script>

<template>
  <div class="app-layout" :class="{ authenticated: auth.isAuthenticated }">
    <nav v-if="auth.isAuthenticated" class="sidebar">
      <router-link to="/" class="sidebar-brand">
        <svg
          viewBox="50 2 120 130"
          width="26"
          aria-hidden="true"
          fill="none"
          stroke="currentColor"
          stroke-width="4.5"
          stroke-linejoin="miter"
          stroke-linecap="square"
        >
          <path
            d="M 58 76 L 60 10 L 92 26 L 128 26 L 160 10 L 162 76 L 130 98 L 90 98 Z"
          />
          <circle cx="88" cy="56" r="15" />
          <circle cx="132" cy="56" r="15" />
          <path d="M 104 74 L 116 74 L 110 87 Z" />
          <path d="M 107 114 L 88 104 L 88 124 Z" />
          <path d="M 113 114 L 132 104 L 132 124 Z" />
        </svg>
        Servant
      </router-link>
      <!-- The brand logo already lands on the dashboard; apps only here,
           the config-flavored surfaces (Data, Sources, Agents) live below. -->
      <ul class="sidebar-nav">
        <li v-for="app in apps.defs" :key="app.id">
          <router-link :to="`/apps/${app.id}`">
            <component :is="appIcons[app.icon] ?? Puzzle" :size="18" />{{
              app.name
            }}
          </router-link>
        </li>
      </ul>
      <router-link
        v-if="photosUploading"
        to="/apps/photos"
        class="sidebar-upload"
        title="Photo upload in progress"
      >
        ⬆ photos
        {{
          photosProgress
            ? `${photosProgress.index}/${photosProgress.total}`
            : ''
        }}
      </router-link>
      <router-link
        v-if="filesUploading"
        to="/apps/files"
        class="sidebar-upload"
        title="File upload in progress"
      >
        ⬆ files
        {{
          filesProgress ? `${filesProgress.index}/${filesProgress.total}` : ''
        }}
      </router-link>
      <router-link to="/data" class="sidebar-settings-link">
        <Database :size="18" />Data
      </router-link>
      <router-link to="/connectors" class="sidebar-settings-link">
        <Cable :size="18" />Sources
      </router-link>
      <router-link v-if="showAgents" to="/agents" class="sidebar-settings-link">
        <Wrench :size="18" />Agents
      </router-link>
      <router-link
        v-if="auth.user?.admin"
        to="/audit"
        class="sidebar-settings-link"
      >
        <Activity :size="18" />Audit
      </router-link>
      <router-link to="/profile" class="sidebar-settings-link">
        <CircleUserRound :size="18" />Profile
      </router-link>
      <router-link to="/settings" class="sidebar-settings-link">
        <Settings :size="18" />Settings
      </router-link>
      <div class="sidebar-footer">
        <button class="logout-btn" @click="handleLogout">
          <LogOut :size="14" />Sign Out
        </button>
      </div>
    </nav>
    <main class="content">
      <router-view />
    </main>
    <ConfirmModal />
    <CommandPalette v-if="auth.isAuthenticated" />
  </div>
</template>
