<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount, nextTick, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useApi } from '../composables/useApi'
import type { Entry } from '../types'
import { kindIcon, kindColor } from '../types'
import { entryRoute } from '../lib/entryRoute'

const router = useRouter()
const api = useApi()

const open = ref(false)
const query = ref('')
const results = ref<Entry[]>([])
const activeIndex = ref(0)
const inputRef = ref<HTMLInputElement | null>(null)

const PAGES = [
  { label: 'Dashboard', path: '/' },
  { label: 'Notes', path: '/apps/notes' },
  { label: 'Checklists', path: '/apps/checklists' },
  { label: 'Calendar', path: '/apps/calendar' },
  { label: 'Photos', path: '/apps/photos' },
  { label: 'Files', path: '/apps/files' },
  { label: 'Contacts', path: '/apps/contacts' },
  { label: 'Data browser', path: '/data' },
  { label: 'Connectors', path: '/connectors' },
  { label: 'Audit', path: '/audit' },
  { label: 'Settings', path: '/settings' }
]

interface Item {
  key: string
  icon: string
  color?: string
  label: string
  hint: string
  path: string
}

const pageItems = computed<Item[]>(() => {
  const q = query.value.trim().toLowerCase()
  return PAGES.filter(p => !q || p.label.toLowerCase().includes(q)).map(p => ({
    key: 'p:' + p.path,
    icon: '→',
    label: p.label,
    hint: 'page',
    path: p.path
  }))
})

const entryItems = computed<Item[]>(() =>
  results.value.map(e => ({
    key: 'e:' + e.id,
    icon: kindIcon(e.kind),
    color: kindColor(e.kind),
    label: e.title || e.kind,
    hint: e.kind,
    path: entryRoute(e)
  }))
)

const items = computed<Item[]>(() => [...entryItems.value, ...pageItems.value])

// Debounced entries search; a sequence counter drops out-of-order responses.
let searchTimer: ReturnType<typeof setTimeout> | undefined
let seq = 0
watch(query, q => {
  activeIndex.value = 0
  if (searchTimer) clearTimeout(searchTimer)
  const term = q.trim()
  if (term.length < 2) {
    results.value = []
    return
  }
  searchTimer = setTimeout(async () => {
    const mySeq = ++seq
    try {
      const res = await api.get<{ data: Entry[] }>('/api/entries', {
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
  const n = items.value.length
  if (n) activeIndex.value = (activeIndex.value + delta + n) % n
}

function onKeydown(e: KeyboardEvent) {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault()
    if (open.value) close()
    else openPalette()
    return
  }
  if (!open.value) return
  if (e.key === 'Escape') {
    close()
  } else if (e.key === 'ArrowDown') {
    e.preventDefault()
    move(1)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    move(-1)
  } else if (e.key === 'Enter') {
    const item = items.value[activeIndex.value]
    if (item) {
      e.preventDefault()
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
            v-for="(item, i) in items"
            :key="item.key"
            class="cp-item"
            :class="{ 'cp-item--active': i === activeIndex }"
            @mousemove="activeIndex = i"
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  color-scheme: dark;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.7rem;
}
</style>
