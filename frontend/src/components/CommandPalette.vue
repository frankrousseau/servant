<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'

import { listEntriesPage } from '../api/entries'
import { agentsEnabled, hiddenEntryKinds } from '../apps/registry'
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
const dialogRef = ref<HTMLDialogElement | null>(null)

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

// The entries of an opt-in slice that the user has off (crypto) stay out of
// the results, as on the dashboard. The data browser stays the raw view.
const visibleResults = computed(() => {
  const hidden = hiddenEntryKinds(auth.user?.enabled_apps)
  return results.value.filter(entry => !hidden.includes(entry.kind))
})

const entryItems = computed<Item[]>(() =>
  visibleResults.value.map(entry => ({
    key: 'e:' + entry.id,
    icon: kindIcon(entry.kind),
    color: kindColor(entry.kind),
    label: entry.title || entry.kind,
    hint: entry.kind,
    path: entryRoute(entry)
  }))
)

const items = computed<Item[]>(() => [...entryItems.value, ...pageItems.value])

// A debounced search of entries. A sequence counter drops the responses that
// arrive out of order.
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
      // Stale or failed search: keep the current results.
    }
  }, 200)
})

function openPalette() {
  open.value = true
  query.value = ''
  results.value = []
  activeIndex.value = 0
}

function close() {
  open.value = false
}

// showModal() gives the palette a focus trap and puts the autofocus on the
// search input. flush: 'post' makes sure that the dialog renders first, ready
// to open.
watch(
  open,
  isOpen => {
    if (isOpen) dialogRef.value?.showModal()
    else dialogRef.value?.close()
  },
  { flush: 'post' }
)

// A click on the backdrop targets the dialog element itself. A click inside
// the box hits the inner panel (the dialog has no padding of its own).
function onDialogClick(event: MouseEvent) {
  if (event.target === dialogRef.value) close()
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
    <dialog
      ref="dialogRef"
      class="cp-dialog"
      aria-label="Command palette"
      @click="onDialogClick"
      @close="open = false"
    >
      <div class="cp-panel">
        <input
          v-model="query"
          class="cp-input"
          type="text"
          placeholder="Search everything, jump to a page…"
          aria-label="Search entries and pages"
          spellcheck="false"
          autofocus
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
    </dialog>
  </Teleport>
</template>

<style scoped>
/* A bare top-layer frame near the top of the viewport. The visible box is
   the inner panel. */
.cp-dialog {
  width: min(560px, calc(100% - 2rem));
  margin: 12vh auto auto;
  padding: 0;
  border: none;
  background: transparent;
}
.cp-dialog::backdrop {
  background: rgba(0, 0, 0, 0.55);
}
.cp-panel {
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
/* The default focus ring would hug the input inside the panel. The visible
   focus indicator is the accent border under the field. */
.cp-input:focus {
  outline: none;
  border-bottom-color: var(--primary);
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
/* The cursor row: a violet rail and a tint, the same language as the rest of
   the system. */
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
