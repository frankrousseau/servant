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
  } else if (event.key === 'Escape') {
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
/* The cursor option: a violet rail and a tint, the same language as the
   list rows. */
.ac-option--active {
  background: rgba(var(--primary-rgb), 0.1);
  box-shadow: inset 2px 0 0 var(--primary);
}
</style>
