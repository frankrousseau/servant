<script setup lang="ts">
import { computed, ref } from 'vue'

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

const filtered = computed(() => {
  const q = props.modelValue.trim().toLowerCase()
  if (!q) return props.options
  return props.options.filter(o => o.toLowerCase().includes(q))
})

function onInput(e: Event) {
  emit('update:modelValue', (e.target as HTMLInputElement).value)
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
  const n = filtered.value.length
  activeIndex.value = (activeIndex.value + delta + n) % n
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'ArrowDown') {
    e.preventDefault()
    move(1)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    move(-1)
  } else if (e.key === 'Enter') {
    if (open.value && activeIndex.value >= 0) {
      e.preventDefault()
      select(filtered.value[activeIndex.value])
    } else {
      emit('select', props.modelValue)
      close()
    }
  } else if (e.key === 'Escape') {
    close()
  }
}
</script>

<template>
  <div class="ac">
    <input
      class="ac-input"
      type="text"
      :value="modelValue"
      :placeholder="placeholder"
      @input="onInput"
      @focus="open = true"
      @blur="close"
      @keydown="onKeydown"
    />
    <div v-if="open && filtered.length" class="ac-list" role="listbox">
      <!-- mousedown.prevent keeps the input focused so blur doesn't
           close the list before the option registers -->
      <div
        v-for="(option, i) in filtered"
        :key="option"
        class="ac-option"
        :class="{ 'ac-option--active': i === activeIndex }"
        role="option"
        :aria-selected="i === activeIndex"
        @mousedown.prevent="select(option)"
        @mousemove="activeIndex = i"
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
  position: absolute;
  top: calc(100% + 4px);
  left: 0;
  right: 0;
  z-index: 30;
  max-height: 220px;
  overflow-y: auto;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
}
.ac-option {
  padding: 0.4rem 0.6rem;
  font-size: 0.85rem;
  cursor: pointer;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* Cursor option: violet rail + tint, same language as list rows */
.ac-option--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
}
</style>
