<script setup lang="ts">
import { computed, ref } from 'vue'
import { ArrowDown, ArrowUp, GripVertical, Pin } from 'lucide-vue-next'

import SearchField from '../components/SearchField.vue'

import { useDragReorder } from '../composables/useDragReorder'
import { appIcon } from '../lib/appIcons'
import { useAppsStore } from '../stores/apps'

// Every app the user has, built-in or installed: open one, pin it to the
// sidebar or take it off, and set the sidebar order. The sidebar lists only
// the pinned ones, so this page is what keeps a long app list reachable.
const apps = useAppsStore()

const query = ref('')

const pinnedIds = computed(() => new Set(apps.pinned.map(app => app.id)))

const cards = computed(() => {
  const needle = query.value.trim().toLowerCase()
  return apps.defs
    .filter(app => !needle || app.name.toLowerCase().includes(needle))
    .map(app => ({
      id: app.id,
      name: app.name,
      icon: appIcon(app.icon),
      origin: app.builtin ? 'Built-in' : 'Installed',
      pinned: pinnedIds.value.has(app.id)
    }))
})

// Rows drag with the mouse; the arrows do the same for the keyboard and
// for touch screens, where HTML drag and drop does not fire.
const {
  draggingId,
  marks,
  onDragStart,
  onDragOver,
  onDragLeave,
  onDrop,
  onDragEnd
} = useDragReorder(
  () => apps.pinned.map(app => app.id),
  (id, toIndex) => apps.placePinned(id, toIndex)
)

const order = computed(() =>
  apps.pinned.map((app, i) => ({
    id: app.id,
    name: app.name,
    icon: appIcon(app.icon),
    first: i === 0,
    last: i === apps.pinned.length - 1
  }))
)
</script>

<template>
  <div class="view launcher">
    <h1>Apps</h1>

    <div class="launcher-layout">
      <div class="launcher-main">
        <SearchField v-model="query" label="Search apps" autofocus />

        <ul v-if="cards.length" class="launcher-grid">
          <li v-for="app in cards" :key="app.id" class="launcher-card">
            <router-link :to="`/apps/${app.id}`" class="launcher-open">
              <component :is="app.icon" :size="28" class="launcher-icon" />
              <span class="launcher-name">{{ app.name }}</span>
              <span class="launcher-origin">{{ app.origin }}</span>
            </router-link>
            <button
              type="button"
              class="launcher-pin"
              :class="{ 'launcher-pin--on': app.pinned }"
              :aria-label="`Pin ${app.name} to the sidebar`"
              :aria-pressed="app.pinned"
              :title="
                app.pinned ? 'Unpin from the sidebar' : 'Pin to the sidebar'
              "
              @click="apps.setPinned(app.id, !app.pinned)"
            >
              <Pin :size="18" :fill="app.pinned ? 'currentColor' : 'none'" />
            </button>
          </li>
        </ul>
        <p v-else class="empty">No app matches "{{ query }}".</p>

        <p class="launcher-hint">
          More built-in apps can be turned on in
          <router-link to="/settings?tab=apps">Settings</router-link>, where you
          can also install apps from a git repository.
        </p>
      </div>

      <!-- Its own column, outside the search: the order always lists every
           pinned app, so a move never jumps over rows hidden by a filter. -->
      <section class="launcher-side" aria-labelledby="launcher-order-title">
        <h2 id="launcher-order-title">Sidebar order</h2>
        <ol v-if="order.length" class="launcher-order" @dragleave="onDragLeave">
          <li
            v-for="(app, i) in order"
            :key="app.id"
            class="launcher-order-row"
            :class="{
              'launcher-order-row--dragging': draggingId === app.id,
              'launcher-order-row--before': marks[app.id] === 'before',
              'launcher-order-row--after': marks[app.id] === 'after'
            }"
            draggable="true"
            @dragstart="onDragStart(app.id, $event)"
            @dragover="onDragOver(i, $event)"
            @drop="onDrop"
            @dragend="onDragEnd"
          >
            <GripVertical :size="16" class="launcher-grip" />
            <component :is="app.icon" :size="18" />
            <span class="launcher-order-name">{{ app.name }}</span>
            <button
              type="button"
              class="launcher-move"
              :aria-label="`Move ${app.name} up`"
              :disabled="app.first"
              @click="apps.movePinned(app.id, -1)"
            >
              <ArrowUp :size="16" />
            </button>
            <button
              type="button"
              class="launcher-move"
              :aria-label="`Move ${app.name} down`"
              :disabled="app.last"
              @click="apps.movePinned(app.id, 1)"
            >
              <ArrowDown :size="16" />
            </button>
          </li>
        </ol>
        <p v-else class="empty">
          No app pinned: the sidebar shows only All apps.
        </p>
      </section>
    </div>
  </div>
</template>

<style scoped>
/* Wider than the default view: the grid and the order column side by side */
.launcher {
  max-width: 1200px;
}

.launcher-layout {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 300px;
  gap: 2rem;
  align-items: start;
}

/* Tablet and below: the order column drops under the grid, and stops
   sticking (it would slide under the fixed top bar) */
@media (max-width: 1024px) {
  .launcher-layout {
    grid-template-columns: minmax(0, 1fr);
  }

  .launcher-side {
    position: static;
  }
}

/* ----- Grid ----- */

.launcher-grid {
  list-style: none;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 0.75rem;
  margin-top: 1rem;
}

.launcher-card {
  position: relative;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  background: var(--bg-surface);
  transition: border-color 0.15s;
}

.launcher-card:hover,
.launcher-card:focus-within {
  border-color: rgba(var(--primary-rgb), 0.5);
}

.launcher-open {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0.35rem;
  padding: 1rem;
  color: var(--text);
}

.launcher-open:hover {
  text-decoration: none;
}

.launcher-icon {
  color: var(--primary);
  margin-bottom: 0.35rem;
}

.launcher-name {
  font-weight: 600;
}

.launcher-origin {
  color: var(--text-muted);
  font-size: 0.875rem;
}

/* 44px square in the card corner: the touch target minimum */
.launcher-pin {
  position: absolute;
  top: 0.25rem;
  right: 0.25rem;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  padding: 0;
  background: transparent;
  color: var(--text-muted);
  transition: color 0.15s;
}

.launcher-pin:hover {
  background: transparent;
  color: var(--text);
}

.launcher-pin--on,
.launcher-pin--on:hover {
  color: var(--primary);
}

/* Phone: a card per row, icon, name and origin on one line, so a long app
   list scrolls like a list instead of a wall of tiles */
@media (max-width: 640px) {
  .launcher-grid {
    grid-template-columns: minmax(0, 1fr);
    gap: 0.5rem;
  }

  .launcher-open {
    flex-direction: row;
    align-items: center;
    gap: 0.75rem;
    padding: 0.6rem 3.25rem 0.6rem 1rem;
    min-height: 56px;
  }

  .launcher-icon {
    flex-shrink: 0;
    width: 22px;
    height: 22px;
    margin-bottom: 0;
  }

  .launcher-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .launcher-pin {
    top: 50%;
    transform: translateY(-50%);
  }
}

/* ----- Sidebar order ----- */

.launcher-side {
  position: sticky;
  top: 1rem;
}

/* The column starts level with the search field, not 1.5rem below it */
.launcher-side h2 {
  margin-top: 0;
}

.launcher-order {
  list-style: none;
  overflow: hidden;
  border: 1px solid var(--border);
  border-radius: var(--radius);
}

.launcher-order-row {
  display: flex;
  align-items: center;
  gap: 0.65rem;
  padding: 0 0.25rem 0 0.5rem;
  background: var(--bg-surface);
  color: var(--text-muted);
  cursor: grab;
}

.launcher-grip {
  flex-shrink: 0;
  opacity: 0.6;
}

/* Touch screens fire no HTML drag and drop: no grip promising one, the
   arrows do the moving */
@media (pointer: coarse) {
  .launcher-order-row {
    padding-left: 0.9rem;
    cursor: default;
  }

  .launcher-grip {
    display: none;
  }
}

.launcher-order-row + .launcher-order-row {
  border-top: 1px solid var(--border);
}

/* Drag to reorder: the dragged row fades, a primary line marks the gap */
.launcher-order-row--dragging {
  opacity: 0.4;
}

.launcher-order-row--before {
  box-shadow: inset 0 2px 0 var(--primary);
}

.launcher-order-row--after {
  box-shadow: inset 0 -2px 0 var(--primary);
}

.launcher-order-name {
  flex: 1;
  color: var(--text);
}

.launcher-move {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  padding: 0;
  background: transparent;
  color: var(--text-muted);
  transition: color 0.15s;
}

.launcher-move:hover:not(:disabled) {
  background: transparent;
  color: var(--text);
}

/* The global disabled look only fades; a move past the end must read as
   unavailable, not as a lighter button. */
.launcher-move:disabled {
  opacity: 0.25;
}

/* ----- Hint ----- */

.launcher-hint {
  margin-top: 1.5rem;
  color: var(--text-muted);
}
</style>
