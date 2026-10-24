<script setup lang="ts">
import { Menu, Search } from 'lucide-vue-next'

import BrandMark from './BrandMark.vue'

import { useCommandPalette } from '../composables/useCommandPalette'

// Below the tablet breakpoint the sidebar leaves the page for a drawer; this
// bar is what stays on screen: the drawer toggle, the brand back to the
// dashboard, and the search (the command palette, which a phone cannot
// reach through Ctrl+K).
defineProps<{ navOpen: boolean }>()
const emit = defineEmits<{ toggleNav: [] }>()

const palette = useCommandPalette()
</script>

<template>
  <header class="topbar">
    <button
      type="button"
      class="topbar-btn"
      aria-label="Menu"
      aria-controls="app-sidebar"
      :aria-expanded="navOpen"
      @click="emit('toggleNav')"
    >
      <Menu :size="22" />
    </button>
    <router-link to="/" class="topbar-brand">
      <BrandMark :size="22" />Servant
    </router-link>
    <button
      type="button"
      class="topbar-btn"
      aria-label="Search"
      @click="palette.toggle()"
    >
      <Search :size="20" />
    </button>
  </header>
</template>

<style scoped>
.topbar {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  z-index: 30;
  height: var(--topbar-height);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding: 0 0.25rem;
  background: var(--bg-surface);
  border-bottom: 1px solid var(--border);
}

/* 44px square: the touch target minimum */
.topbar-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  padding: 0;
  background: transparent;
  color: var(--text-muted);
}

.topbar-btn:hover {
  background: var(--bg-hover);
  color: var(--text);
}

.topbar-brand {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-family: var(--font-display);
  font-size: var(--text-lg);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--primary);
  text-shadow: 0 0 8px rgba(var(--primary-rgb), 0.55);
}

.topbar-brand:hover {
  text-decoration: none;
}
</style>
