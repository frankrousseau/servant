<script setup lang="ts">
import { ref } from 'vue'
import { Search, X } from 'lucide-vue-next'

// The Servant search box: a labelled field with a search icon, a clear
// button and Escape to clear. `autofocus` makes it the page's landing focus
// (AGENTS.md: default focus goes to the search field when there is one):
// the directive focuses it on mount, and the native attribute is what
// showModal() reads when the field sits in a dialog.
//
// <SearchField v-model="query" label="Search notes" autofocus />
const props = withDefaults(
  defineProps<{
    modelValue: string
    // Accessible name, required: a placeholder is not a label.
    label: string
    placeholder?: string
    autofocus?: boolean
  }>(),
  { placeholder: undefined, autofocus: false }
)
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const input = ref<HTMLInputElement | null>(null)

function clear() {
  emit('update:modelValue', '')
  input.value?.focus()
}

// Escape clears a filled field and stops there; on an empty field it is
// left alone, so a surrounding dialog or viewer still closes on it.
function onKeydown(event: KeyboardEvent) {
  if (event.key !== 'Escape' || !props.modelValue) return
  event.preventDefault()
  event.stopPropagation()
  clear()
}
</script>

<template>
  <div class="search-field">
    <Search class="search-field-icon" :size="15" aria-hidden="true" />
    <input
      ref="input"
      v-autofocus="autofocus"
      :autofocus="autofocus"
      type="search"
      class="search-field-input"
      :value="modelValue"
      :placeholder="placeholder ?? `${label}...`"
      :aria-label="label"
      @input="
        emit('update:modelValue', ($event.target as HTMLInputElement).value)
      "
      @keydown="onKeydown"
    />
    <button
      v-if="modelValue"
      type="button"
      class="search-field-clear"
      aria-label="Clear search"
      @click="clear"
    >
      <X :size="14" />
    </button>
  </div>
</template>

<style scoped>
.search-field {
  position: relative;
  display: flex;
  align-items: center;
  min-width: 0;
}

.search-field-icon {
  position: absolute;
  left: 0.6rem;
  color: var(--text-muted);
  pointer-events: none;
}

.search-field-input {
  width: 100%;
  padding-left: 2rem;
  padding-right: 2rem;
}

/* The clear button below replaces the browser's own (WebKit only). */
.search-field-input::-webkit-search-cancel-button {
  appearance: none;
}

.search-field-clear {
  position: absolute;
  right: 0.35rem;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0.2rem;
  border: none;
  border-radius: var(--radius);
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
}

.search-field-clear:hover {
  background: var(--bg-hover);
  color: var(--text);
}

@media (pointer: coarse) {
  .search-field-clear {
    min-width: 36px;
    min-height: 36px;
    right: 0.15rem;
  }
}
</style>
