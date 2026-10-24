<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { ChevronDown } from 'lucide-vue-next'

// Styled replacement for native <select>: the OS dropdown can't be themed,
// this one speaks the night-terminal language (violet rail on the active
// option). Closed-list single choice; long lists get an inline filter.

type RawOption = string | { value: string; label: string }

const props = defineProps<{
  modelValue: string
  options: RawOption[]
  placeholder?: string
}>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

interface Option {
  value: string
  label: string
}

const opts = computed<Option[]>(() =>
  props.options.map(option =>
    typeof option === 'string' ? { value: option, label: option } : option
  )
)

const open = ref(false)
const activeIndex = ref(-1)
const query = ref('')
const root = ref<HTMLElement | null>(null)
const buttonEl = ref<HTMLButtonElement | null>(null)
const listEl = ref<HTMLElement | null>(null)
const panelEl = ref<HTMLElement | null>(null)
const searchEl = ref<HTMLInputElement | null>(null)

// Long lists (timezones, albums…) get a filter box inside the panel.
const searchable = computed(() => opts.value.length > 12)

const filtered = computed<Option[]>(() => {
  const needle = query.value.trim().toLowerCase()
  if (!needle) return opts.value
  return opts.value.filter(option =>
    option.label.toLowerCase().includes(needle)
  )
})

const currentLabel = computed(
  () =>
    opts.value.find(option => option.value === props.modelValue)?.label ?? ''
)

watch(query, () => {
  activeIndex.value = filtered.value.length ? 0 : -1
})

// The panel teleports to <body> (overflow ancestors would clip an inline
// dropdown) and is fixed-positioned from the control's rect; scrolling any
// ancestor repositions it. Flips above when the viewport bottom is close,
// and stays inside the viewport sideways (a combo near a phone's right edge).
const panelStyle = ref<Record<string, string>>({})
// Gap kept between the panel and the viewport edges
const EDGE = 8
// Inside a modal <dialog>, the panel must live in that dialog: an open modal
// sits in the browser's top layer, above anything in <body> whatever its
// z-index, so a panel teleported to <body> would open hidden behind it.
const panelHost = ref<HTMLElement | string>('body')

function reposition() {
  const rect = root.value?.getBoundingClientRect()
  if (!rect) return
  const viewportWidth = window.innerWidth
  const spaceBelow = window.innerHeight - rect.bottom
  const openUp = spaceBelow < 280 && rect.top > spaceBelow
  const maxWidth = Math.min(320, viewportWidth - 2 * EDGE)
  // Rendered width once open, else the widest it can get
  const width = Math.max(panelEl.value?.offsetWidth ?? maxWidth, rect.width)
  const left = Math.max(
    EDGE,
    Math.min(rect.left, viewportWidth - EDGE - Math.min(width, maxWidth))
  )
  // The list shrinks to the room left on the side it opens towards
  const room = (openUp ? rect.top : spaceBelow) - 4 - EDGE
  panelStyle.value = {
    left: `${left}px`,
    minWidth: `${Math.min(rect.width, maxWidth)}px`,
    maxWidth: `${maxWidth}px`,
    '--cb-list-max': `${Math.max(120, Math.min(240, room - 8))}px`,
    ...(openUp
      ? { bottom: `${window.innerHeight - rect.top + 4}px` }
      : { top: `${rect.bottom + 4}px` })
  }
}

function watchViewport(on: boolean) {
  if (on) {
    window.addEventListener('scroll', reposition, true)
    window.addEventListener('resize', reposition)
  } else {
    window.removeEventListener('scroll', reposition, true)
    window.removeEventListener('resize', reposition)
  }
}

onBeforeUnmount(() => watchViewport(false))

// On searchable combos the control itself becomes the filter input while
// open; swapping focused elements fires a focusout with no related target,
// which must not close the panel we just opened.
let swapping = false

function openPanel() {
  panelHost.value = root.value?.closest('dialog') ?? 'body'
  open.value = true
  query.value = ''
  activeIndex.value = opts.value.findIndex(
    option => option.value === props.modelValue
  )
  reposition()
  watchViewport(true)
  swapping = true
  void nextTick(() => {
    searchEl.value?.focus()
    swapping = false
    // Second pass with the panel's real width, for the sideways clamp
    reposition()
    scrollActiveIntoView()
  })
}

function close() {
  open.value = false
  activeIndex.value = -1
  query.value = ''
  watchViewport(false)
}

function toggle() {
  if (open.value) close()
  else openPanel()
}

function select(option: Option) {
  emit('update:modelValue', option.value)
  close()
  void nextTick(() => buttonEl.value?.focus())
}

function move(delta: number) {
  const count = filtered.value.length
  if (!count) return
  activeIndex.value = (activeIndex.value + delta + count) % count
  void nextTick(scrollActiveIntoView)
}

function scrollActiveIntoView() {
  const el = listEl.value?.querySelector('.cb-option--active')
  ;(el as HTMLElement | null)?.scrollIntoView?.({ block: 'nearest' })
}

// Type-to-jump, like a native select (types straight through when closed).
let typeBuffer = ''
let typeTimer: ReturnType<typeof setTimeout> | undefined

function typeahead(key: string) {
  typeBuffer += key.toLowerCase()
  if (typeTimer) clearTimeout(typeTimer)
  typeTimer = setTimeout(() => (typeBuffer = ''), 500)
  const idx = filtered.value.findIndex(option =>
    option.label.toLowerCase().startsWith(typeBuffer)
  )
  if (idx === -1) return
  if (open.value) {
    activeIndex.value = idx
    void nextTick(scrollActiveIntoView)
  } else {
    select(filtered.value[idx])
  }
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault()
    if (!open.value) openPanel()
    else move(event.key === 'ArrowDown' ? 1 : -1)
  } else if (
    event.key === 'Enter' ||
    (event.key === ' ' && !(searchable.value && open.value))
  ) {
    if (!open.value) {
      event.preventDefault()
      openPanel()
    } else if (activeIndex.value >= 0 && filtered.value[activeIndex.value]) {
      event.preventDefault()
      select(filtered.value[activeIndex.value])
    }
  } else if (event.key === 'Escape') {
    if (open.value) {
      event.stopPropagation()
      close()
      void nextTick(() => buttonEl.value?.focus())
    }
  } else if (
    event.key.length === 1 &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    !(searchable.value && open.value)
  ) {
    typeahead(event.key)
  }
}

function onFocusout(event: FocusEvent) {
  if (swapping) return
  if (!root.value?.contains(event.relatedTarget as Node)) close()
}
</script>

<template>
  <div ref="root" class="cb" @keydown="onKeydown" @focusout="onFocusout">
    <!-- While a searchable combo is open, the control itself is the filter:
         choices appear right away and typing narrows them in place. -->
    <input
      v-if="searchable && open"
      ref="searchEl"
      v-model="query"
      class="cb-control cb-filter"
      type="text"
      role="combobox"
      aria-expanded="true"
      aria-autocomplete="list"
      :placeholder="currentLabel || placeholder || ''"
      autocomplete="off"
      spellcheck="false"
    />
    <button
      v-else
      ref="buttonEl"
      type="button"
      class="cb-control"
      role="combobox"
      :aria-expanded="open"
      @click="toggle"
    >
      <span
        class="cb-value"
        :class="{ 'cb-value--placeholder': !currentLabel }"
      >
        {{ currentLabel || placeholder || '' }}
      </span>
      <span class="cb-caret" aria-hidden="true"
        ><ChevronDown :size="16"
      /></span>
    </button>
    <Teleport :to="panelHost">
      <div v-if="open" ref="panelEl" class="cb-panel" :style="panelStyle">
        <div ref="listEl" class="cb-list" role="listbox">
          <div
            v-for="(option, index) in filtered"
            :key="option.value"
            class="cb-option"
            :class="{
              'cb-option--active': index === activeIndex,
              'cb-option--selected': option.value === modelValue
            }"
            role="option"
            :aria-selected="option.value === modelValue"
            @mousedown.prevent="select(option)"
            @mousemove="activeIndex = index"
          >
            {{ option.label }}
          </div>
          <p v-if="!filtered.length" class="cb-empty">No match.</p>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.cb {
  position: relative;
  min-width: 0;
}
.cb-control {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--bg);
  border: 1px solid var(--border-strong);
  border-radius: var(--control-radius);
  color: var(--text);
  /* Same vertical metrics as the global input rule, so a combo sitting
     next to a text input lines up. */
  padding: 0.5rem 0.9rem;
  font-size: 1rem;
  line-height: 1.4;
  cursor: pointer;
  text-align: left;
}
.cb-control:hover,
.cb-control:focus-visible {
  border-color: var(--primary);
}
.cb-value {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cb-value--placeholder {
  color: var(--text-muted);
}
.cb-caret {
  display: inline-flex;
  color: var(--text-muted);
  flex-shrink: 0;
}
.cb-filter {
  border-color: var(--primary);
  cursor: text;
}
.cb-filter:focus {
  outline: none;
}
.cb-filter::placeholder {
  color: var(--text-muted);
}
.cb-panel {
  /* Teleported to <body>; sits above modal overlays (z 100). */
  position: fixed;
  z-index: 200;
  width: max-content;
  max-width: 320px;
  background: var(--bg-raised);
  border: 1px solid var(--border);
  border-radius: var(--control-radius);
  box-shadow: var(--shadow-raised);
  overflow: hidden;
  padding: 0.25rem;
}
.cb-list {
  max-height: var(--cb-list-max, 240px);
  overflow-y: auto;
}
.cb-option {
  padding: 0.42rem 0.65rem;
  /* Flat left edge, flush with the active rail (same as palette rows). */
  border-radius: 0 6px 6px 0;
  font-size: 0.85rem;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* Cursor option: violet rail + tint, same language as list rows */
.cb-option--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
}
.cb-option--selected {
  color: var(--primary);
}
/* Finger-sized rows on touch screens */
@media (pointer: coarse) {
  .cb-option {
    padding: 0.7rem 0.75rem;
    font-size: 0.95rem;
    /* A narrow screen wraps a long label instead of cutting it */
    white-space: normal;
  }
}
.cb-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.78rem;
  padding: 0.6rem 0.65rem;
  margin: 0;
}
</style>
