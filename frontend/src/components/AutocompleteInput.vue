<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'

const props = defineProps<{
  modelValue: string
  options: string[]
  placeholder?: string
}>()
const emit = defineEmits<{
  'update:modelValue': [value: string]
  select: [value: string]
}>()

const open = ref(false)
const activeIndex = ref(-1)
const input = ref<HTMLInputElement | null>(null)

// The list is fixed-positioned from the input's rect rather than absolute:
// an ancestor that scrolls (a dialog body, a phone modal) would clip an
// absolute list. It flips above the input when the room below runs out, and
// follows the input while any ancestor scrolls.
const listStyle = ref<Record<string, string>>({})
const LIST_MAX = 220
const GAP = 4

function reposition() {
  const rect = input.value?.getBoundingClientRect()
  if (!rect) return
  const below = window.innerHeight - rect.bottom
  const openUp = below < LIST_MAX + GAP && rect.top > below
  listStyle.value = {
    left: `${rect.left}px`,
    width: `${rect.width}px`,
    ...(openUp
      ? { bottom: `${window.innerHeight - rect.top + GAP}px` }
      : { top: `${rect.bottom + GAP}px` })
  }
}

watch(open, isOpen => {
  if (isOpen) {
    reposition()
    window.addEventListener('scroll', reposition, true)
    window.addEventListener('resize', reposition)
  } else {
    window.removeEventListener('scroll', reposition, true)
    window.removeEventListener('resize', reposition)
  }
})

onBeforeUnmount(() => {
  window.removeEventListener('scroll', reposition, true)
  window.removeEventListener('resize', reposition)
})

const filtered = computed(() => {
  const query = props.modelValue.trim().toLowerCase()
  if (!query) return props.options
  return props.options.filter(option => option.toLowerCase().includes(query))
})

function onInput(event: Event) {
  emit('update:modelValue', (event.target as HTMLInputElement).value)
  open.value = true
  activeIndex.value = -1
}

function select(option: string) {
  emit('update:modelValue', option)
  emit('select', option)
  close()
}

function close() {
  open.value = false
  activeIndex.value = -1
}

function move(delta: number) {
  if (!filtered.value.length) return
  open.value = true
  const count = filtered.value.length
  activeIndex.value = (activeIndex.value + delta + count) % count
}

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    move(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    move(-1)
  } else if (event.key === 'Enter') {
    if (open.value && activeIndex.value >= 0) {
      event.preventDefault()
      select(filtered.value[activeIndex.value])
    } else {
      emit('select', props.modelValue)
      close()
    }
  } else if (event.key === 'Escape' && open.value && filtered.value.length) {
    // Only the list closes: a surrounding dialog stays open.
    event.preventDefault()
    event.stopPropagation()
    close()
  }
}
</script>

<template>
  <div class="ac">
    <input
      ref="input"
      class="ac-input"
      type="text"
      :value="modelValue"
      :placeholder="placeholder"
      @input="onInput"
      @focus="open = true"
      @blur="close"
      @keydown="onKeydown"
    />
    <div
      v-if="open && filtered.length"
      class="ac-list"
      role="listbox"
      :style="listStyle"
    >
      <!-- mousedown.prevent keeps the focus on the input. As a result, blur
           does not close the list before the option registers. -->
      <div
        v-for="(option, index) in filtered"
        :key="option"
        class="ac-option"
        :class="{ 'ac-option--active': index === activeIndex }"
        role="option"
        :aria-selected="index === activeIndex"
        @mousedown.prevent="select(option)"
        @mousemove="activeIndex = index"
      >
        {{ option }}
      </div>
    </div>
  </div>
</template>

<style scoped>
.ac {
  position: relative;
}
.ac-input {
  width: 100%;
}
.ac-list {
  /* Coordinates come from reposition() */
  position: fixed;
  z-index: 30;
  max-height: 220px;
  overflow-y: auto;
  background: var(--bg-raised);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow-raised);
}
.ac-option {
  padding: 0.4rem 0.6rem;
  font-size: var(--text-sm);
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* Finger-sized rows on touch screens */
@media (pointer: coarse) {
  .ac-option {
    padding: 0.7rem 0.75rem;
    font-size: var(--text-base);
  }
}
/* The cursor option: a violet rail and a tint, the same language as the
   list rows. */
.ac-option--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
}
</style>
