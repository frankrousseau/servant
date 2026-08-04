<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'

import { listEntriesPage } from '../api/entries'
import { agentsEnabled } from '../apps/registry'
import { entryRoute } from '../lib/entryRoute'
import { kindColor, kindIcon } from '../lib/kind'
import { useAppsStore } from '../stores/apps'
import { useAuthStore } from '../stores/auth'
import type { Entry } from '../types'

const router = useRouter()

const open = ref(false)
const query = ref('')
const results = ref<Entry[]>([])
const activeIndex = ref(0)
const inputRef = ref<HTMLInputElement | null>(null)

const appsStore = useAppsStore()
const auth = useAuthStore()

// Apps come from the store, so disabled built-ins stay out of the palette.
const pages = computed(() => [
  { label: 'Dashboard', path: '/' },
  ...appsStore.defs.map(app => ({ label: app.name, path: `/apps/${app.id}` })),
  { label: 'Data browser', path: '/data' },
  { label: 'Connectors', path: '/connectors' },
  ...(agentsEnabled(auth.user?.enabled_apps)
    ? [{ label: 'Agents', path: '/agents' }]
    : []),
  { label: 'Audit', path: '/audit' },
  { label: 'Settings', path: '/settings' }
])

interface Item {
  key: string
  icon: string
  color?: string
  label: string
  hint: string
  path: string
}

const pageItems = computed<Item[]>(() => {
  const needle = query.value.trim().toLowerCase()
  return pages.value
    .filter(page => !needle || page.label.toLowerCase().includes(needle))
    .map(page => ({
      key: 'p:' + page.path,
      icon: '→',
      label: page.label,
      hint: 'page',
      path: page.path
    }))
})

const entryItems = computed<Item[]>(() =>
  results.value.map(entry => ({
    key: 'e:' + entry.id,
    icon: kindIcon(entry.kind),
    color: kindColor(entry.kind),
    label: entry.title || entry.kind,
    hint: entry.kind,
    path: entryRoute(entry)
  }))
)

const items = computed<Item[]>(() => [...entryItems.value, ...pageItems.value])

// Debounced entries search; a sequence counter drops out-of-order responses.
let searchTimer: ReturnType<typeof setTimeout> | undefined
let seq = 0
watch(query, text => {
  activeIndex.value = 0
  if (searchTimer) clearTimeout(searchTimer)
  const term = text.trim()
  if (term.length < 2) {
    results.value = []
    return
  }
  searchTimer = setTimeout(async () => {
    const mySeq = ++seq
    try {
      const res = await listEntriesPage({
        q: term,
        per_page: '12',
        sort: 'inserted_at'
      })
      if (mySeq === seq) results.value = res.data
    } catch {
      // stale or failed search: keep what we have
    }
  }, 200)
})

function openPalette() {
  open.value = true
  query.value = ''
  results.value = []
  activeIndex.value = 0
  void nextTick(() => inputRef.value?.focus())
}

function close() {
  open.value = false
}

function go(item: Item) {
  close()
  void router.push(item.path)
}

function move(delta: number) {
  const count = items.value.length
  if (count) activeIndex.value = (activeIndex.value + delta + count) % count
}

function onKeydown(event: KeyboardEvent) {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault()
    if (open.value) close()
    else openPalette()
    return
  }
  if (!open.value) return
  if (event.key === 'Escape') {
    close()
  } else if (event.key === 'ArrowDown') {
    event.preventDefault()
    move(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    move(-1)
  } else if (event.key === 'Enter') {
    const item = items.value[activeIndex.value]
    if (item) {
      event.preventDefault()
      go(item)
    }
  }
}

onMounted(() => document.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown)
  if (searchTimer) clearTimeout(searchTimer)
})
</script>

<template>
  <Teleport to="body">
    <div v-if="open" class="cp-overlay" @click.self="close">
      <div class="cp-panel">
        <input
          ref="inputRef"
          v-model="query"
          class="cp-input"
          type="text"
          placeholder="Search everything, jump to a page…"
          spellcheck="false"
        />
        <div class="cp-list">
          <div
            v-for="(item, index) in items"
            :key="item.key"
            class="cp-item"
            :class="{ 'cp-item--active': index === activeIndex }"
            @mousemove="activeIndex = index"
            @mousedown.prevent="go(item)"
          >
            <span
              class="cp-icon"
              :style="item.color ? { color: item.color } : undefined"
              >{{ item.icon }}</span
            >
            <span class="cp-label">{{ item.label }}</span>
            <span class="cp-hint">{{ item.hint }}</span>
          </div>
          <p v-if="!items.length" class="cp-empty">No matches.</p>
        </div>
        <div class="cp-footer">↑↓ navigate · ↵ open · esc close</div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.cp-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.55);
  z-index: 200;
  display: flex;
  justify-content: center;
  align-items: flex-start;
  padding-top: 12vh;
}
.cp-panel {
  width: 100%;
  max-width: 560px;
  margin: 0 1rem;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.6);
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.cp-input {
  border: none;
  border-radius: 0;
  border-bottom: 1px solid var(--border);
  background: transparent;
  padding: 0.85rem 1rem;
  font-size: 1rem;
  font-family: var(--font-mono);
}
.cp-input:focus {
  outline: none;
}
.cp-list {
  max-height: 46vh;
  overflow-y: auto;
  padding: 0.35rem;
}
.cp-item {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
  padding: 0.45rem 0.6rem;
  cursor: pointer;
  font-size: 0.92rem;
}
/* Cursor row: violet rail + tint, same language as the rest of the system */
.cp-item--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
  border-radius: 0 6px 6px 0;
}
.cp-icon {
  width: 1.2em;
  flex-shrink: 0;
  text-align: center;
  font-family: var(--font-mono);
}
.cp-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cp-hint {
  margin-left: auto;
  flex-shrink: 0;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.cp-empty {
  color: var(--text-muted);
  text-align: center;
  padding: 1.25rem;
  font-size: 0.9rem;
  margin: 0;
}
.cp-footer {
  border-top: 1px solid var(--border);
  padding: 0.4rem 1rem;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.7rem;
}
</style>
