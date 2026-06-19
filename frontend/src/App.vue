<script setup lang="ts">
import { useAuthStore } from "./stores/auth";
import { useRouter } from "vue-router";
import { LayoutDashboard, Database, Cable, Settings, LogOut, UserRound, CalendarDays, FolderOpen, Image } from "lucide-vue-next";
import { BUILTIN_APPS } from "./apps/registry";
import ConfirmModal from "./components/ConfirmModal.vue";

const appIcons: Record<string, unknown> = { UserRound, CalendarDays, FolderOpen, Image };

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
      <div class="sidebar-brand">Servant</div>
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
