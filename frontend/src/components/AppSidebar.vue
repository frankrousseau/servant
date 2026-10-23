<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import {
  Activity,
  Brain,
  Cable,
  CalendarDays,
  CircleUserRound,
  Database,
  FolderOpen,
  Image,
  ListChecks,
  LogOut,
  NotebookPen,
  Puzzle,
  Settings,
  Target,
  Upload,
  UserRound,
  Wallet,
  Wrench
} from 'lucide-vue-next'

import BrandMark from './BrandMark.vue'

import {
  uploadProgress as filesProgress,
  uploading as filesUploading
} from '../apps/files/uploadQueue'
import {
  uploadProgress as photosProgress,
  uploading as photosUploading
} from '../apps/photos/uploadQueue'
import { agentsEnabled } from '../apps/registry'
import { useAppsStore } from '../stores/apps'
import { useAuthStore } from '../stores/auth'

// An app declares its icon by name in the registry, which stays free of Vue
// imports; the mapping to a component lives here, where they are rendered.
const appIcons: Record<string, unknown> = {
  Brain,
  UserRound,
  CalendarDays,
  FolderOpen,
  Image,
  NotebookPen,
  ListChecks,
  Wallet,
  Target
}

// In drawer mode (below the tablet breakpoint) the nav slides in over the
// page from the top bar's toggle; closed, it is inert so neither the tab
// order nor assistive tech can reach links that are off screen.
const props = defineProps<{ drawer: boolean; open: boolean }>()
const emit = defineEmits<{ close: [] }>()

const hidden = computed(() => props.drawer && !props.open)

const auth = useAuthStore()
const apps = useAppsStore()
const router = useRouter()

const showAgents = computed(() => agentsEnabled(auth.user?.enabled_apps))

function handleLogout() {
  auth.logout()
  router.push('/login')
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
    :class="{ 'sidebar--drawer': drawer, 'sidebar--open': drawer && open }"
    aria-label="Main"
    :inert="hidden"
    @keydown.escape="emit('close')"
  >
    <router-link to="/" class="sidebar-brand">
      <BrandMark :size="26" />
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
  padding: 1rem 0;
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
  padding: 0.5rem 1.25rem 1.25rem;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(var(--primary-rgb), 0.55);
}

.sidebar-brand svg {
  flex-shrink: 0;
  filter: drop-shadow(0 0 6px rgba(var(--primary-rgb), 0.45));
}

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

.sidebar-footer {
  padding: 1rem 1.25rem;
  border-top: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.logout-btn {
  background: none;
  border: none;
  color: var(--text-muted);
  padding: 0.35rem 0;
  cursor: pointer;
  font-size: 0.9rem;
  display: flex;
  align-items: center;
  gap: 0.4rem;
}

.logout-btn:hover {
  color: var(--text);
  background: none;
}
</style>
