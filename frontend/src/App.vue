<script setup lang="ts">
import { useAuthStore } from "./stores/auth";
import { useRouter } from "vue-router";
import { LayoutDashboard, Database, Cable, Settings, LogOut, UserRound, CalendarDays, FolderOpen, Image, NotebookPen, ListChecks, Activity } from "lucide-vue-next";
import { BUILTIN_APPS } from "./apps/registry";
import ConfirmModal from "./components/ConfirmModal.vue";

const appIcons: Record<string, unknown> = { UserRound, CalendarDays, FolderOpen, Image, NotebookPen, ListChecks };

const auth = useAuthStore();
const router = useRouter();

function handleLogout() {
  auth.logout();
  router.push("/login");
}
</script>

<template>
  <div class="app-layout" :class="{ authenticated: auth.isAuthenticated }">
    <nav v-if="auth.isAuthenticated" class="sidebar">
      <router-link to="/" class="sidebar-brand">
        <svg viewBox="50 2 120 130" width="26" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="4.5" stroke-linejoin="miter" stroke-linecap="square">
          <path d="M 58 76 L 60 10 L 92 26 L 128 26 L 160 10 L 162 76 L 130 98 L 90 98 Z"/>
          <circle cx="88" cy="56" r="15"/>
          <circle cx="132" cy="56" r="15"/>
          <path d="M 104 74 L 116 74 L 110 87 Z"/>
          <path d="M 107 114 L 88 104 L 88 124 Z"/>
          <path d="M 113 114 L 132 104 L 132 124 Z"/>
        </svg>
        Servant
      </router-link>
      <ul class="sidebar-nav">
        <li>
          <router-link to="/">
            <LayoutDashboard :size="18" />Dashboard
          </router-link>
        </li>
        <li v-for="app in BUILTIN_APPS" :key="app.id">
          <router-link :to="`/apps/${app.id}`">
            <component :is="appIcons[app.icon]" :size="18" />{{ app.name }}
          </router-link>
        </li>
        <li>
          <router-link to="/data">
            <Database :size="18" />Data
          </router-link>
        </li>
        <li>
          <router-link to="/connectors">
            <Cable :size="18" />Sources
          </router-link>
        </li>
      </ul>
      <router-link to="/audit" class="sidebar-settings-link">
        <Activity :size="18" />Audit
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
  </div>
</template>
