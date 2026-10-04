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
  UserRound,
  Wallet,
  Wrench
} from 'lucide-vue-next'

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

// An app declares its icon by name in the registry, so the registry has no
// Vue imports. The mapping to a component is here, where the icons render.
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
  <nav class="sidebar">
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
    <!-- The brand logo already goes to the dashboard. This list has only the
         apps. The surfaces for configuration (Data, Sources, Agents) are
         below. -->
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
        photosProgress ? `${photosProgress.index}/${photosProgress.total}` : ''
      }}
    </router-link>
    <router-link
      v-if="filesUploading"
      to="/apps/files"
      class="sidebar-upload"
      title="File upload in progress"
    >
      ⬆ files
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
/* These rules moved here with the markup. The `:deep(svg)` rule below now
   applies. Before, the rule was in the global sheet, where that Vue-only
   selector is invalid. As a result, the lucide icons sometimes shrank when
   the app name was long. */
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
}

/* The owl-butler logo and the wordmark. They link back to the dashboard. */
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

/* vue-router sets aria-current="page" on the exact active link. A style on
   the attribute keeps the announced state and the visible state in sync. */
.sidebar-nav li a[aria-current='page'] {
  color: var(--text);
}

/* The global pulse of the photo upload: the queue continues to run when the
   user goes to another app. */
.sidebar-upload {
  display: block;
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

/* aria-current covers the exact page. .router-link-active stays for the
   ancestor case: it keeps Sources lit on a child page (/connectors/:id). */
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
