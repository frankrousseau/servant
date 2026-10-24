<script setup lang="ts">
import { ref, useId, useSlots } from 'vue'
import { X } from 'lucide-vue-next'

import { openDialog } from '../lib/dialog'

// The Servant modal: a native <dialog> opened with showModal() (top layer,
// focus trap, Escape, focus restoration), its title wired to
// aria-labelledby, an icon and a text close button, and the shared
// header / body / actions layout. Every way out (Escape, backdrop click,
// either close button) goes through one `update:open` false, so the parent
// state cannot drift from what the browser shows.
//
// <ServantDialog v-model:open="editing" title="Edit event">
//   ...fields...
//   <template #actions><button autofocus @click="save">Save</button></template>
// </ServantDialog>
//
// #start-actions holds an action set apart on the left (Delete), before the
// close button in tab order too. A dialog without a primary action (a list
// to read) passes initial-focus="close" so focus lands on the text button
// rather than on the icon one. In the lg and xl boxes, made for lists, the
// body scrolls inside the box once it outgrows the screen while the header
// and the actions stay in view. The sm and md form boxes grow instead: a
// scrolling body would clip the suggestion list of an AutocompleteInput.
const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    size?: 'sm' | 'md' | 'lg' | 'xl'
    // Label of the text close button; "Cancel" next to actions, else "Close".
    closeLabel?: string
    initialFocus?: 'close'
  }>(),
  { size: 'md', closeLabel: undefined, initialFocus: undefined }
)
const emit = defineEmits<{ 'update:open': [value: boolean]; close: [] }>()
const slots = useSlots()

const titleId = useId()
// A press that starts inside the box and ends on the backdrop (selecting
// text in a field, then dragging out) is not a backdrop click.
const pressedOnBackdrop = ref(false)

function close() {
  emit('update:open', false)
  emit('close')
}

function onPointerDown(event: PointerEvent) {
  pressedOnBackdrop.value = event.target === event.currentTarget
}

function onClick(event: MouseEvent) {
  if (pressedOnBackdrop.value && event.target === event.currentTarget) close()
  pressedOnBackdrop.value = false
}

// The native cancel would close the element behind Vue's back; the v-if
// unmounts it instead, once the parent has updated `open`.
function onCancel(event: Event) {
  event.preventDefault()
  close()
}
</script>

<template>
  <dialog
    v-if="props.open"
    :ref="openDialog"
    class="servant-dialog"
    :aria-labelledby="titleId"
    @pointerdown="onPointerDown"
    @click="onClick"
    @cancel="onCancel"
  >
    <div class="servant-dialog-box" :class="`servant-dialog-box--${size}`">
      <header class="servant-dialog-header">
        <h2 :id="titleId" class="servant-dialog-title">
          <slot name="title">{{ title }}</slot>
        </h2>
        <button
          type="button"
          class="servant-dialog-x"
          aria-label="Close"
          @click="close"
        >
          <X :size="18" />
        </button>
      </header>
      <div class="servant-dialog-body">
        <slot />
      </div>
      <footer class="servant-dialog-actions">
        <div v-if="slots['start-actions']" class="servant-dialog-start">
          <slot name="start-actions" />
        </div>
        <button
          type="button"
          class="servant-dialog-cancel"
          :autofocus="initialFocus === 'close'"
          @click="close"
        >
          {{ closeLabel ?? (slots.actions ? 'Cancel' : 'Close') }}
        </button>
        <slot name="actions" />
      </footer>
    </div>
  </dialog>
</template>

<style scoped>
/* The <dialog> is a transparent full-width frame in the top layer, centered
   by the UA; the visible box is the inner wrapper, so a click that lands on
   the dialog element itself is a backdrop click. */
.servant-dialog {
  width: 100%;
  max-width: none;
  padding: 0;
  border: none;
  background: transparent;
}

.servant-dialog[open] {
  display: flex;
  justify-content: center;
}

.servant-dialog::backdrop {
  background: rgba(0, 0, 0, 0.6);
}

/* Opening fade; closing is instant (the v-if removes the element). */
.servant-dialog,
.servant-dialog::backdrop {
  opacity: 1;
  transition: opacity 0.15s;
}

@starting-style {
  .servant-dialog[open],
  .servant-dialog[open]::backdrop {
    opacity: 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  .servant-dialog,
  .servant-dialog::backdrop {
    transition: none;
  }
}

/* ----- Box ----- */
.servant-dialog-box {
  display: flex;
  flex-direction: column;
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1.5rem;
  width: 100%;
}

.servant-dialog-box--sm {
  max-width: 400px;
}

.servant-dialog-box--md {
  max-width: 500px;
}

.servant-dialog-box--lg {
  max-width: 760px;
}

.servant-dialog-box--xl {
  max-width: 1100px;
}

.servant-dialog-box--lg,
.servant-dialog-box--xl {
  max-height: calc(100dvh - 3rem);
}

/* ----- Header ----- */
.servant-dialog-header {
  flex-shrink: 0;
  display: flex;
  align-items: flex-start;
  gap: 0.75rem;
  margin-bottom: 1rem;
}

.servant-dialog-title {
  flex: 1;
  margin: 0;
  font-size: 1.05rem;
  font-weight: 600;
}

.servant-dialog-x {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0.25rem;
  border: none;
  border-radius: var(--radius);
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
}

.servant-dialog-x:hover {
  background: var(--bg-hover);
  color: var(--text);
}

/* ----- Body ----- */
.servant-dialog-box--lg .servant-dialog-body,
.servant-dialog-box--xl .servant-dialog-body {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

/* ----- Actions ----- */
.servant-dialog-actions {
  flex-shrink: 0;
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.5rem;
  margin-top: 1.25rem;
}

.servant-dialog-start {
  display: flex;
  gap: 0.5rem;
  margin-right: auto;
}

.servant-dialog-cancel {
  background: transparent;
  border-color: var(--border);
  color: var(--text-muted);
}

.servant-dialog-cancel:hover {
  background: var(--bg-hover);
  color: var(--text);
}

/* Phones: a gutter on both sides, and a box taller than the screen scrolls
   inside itself. */
@media (max-width: 640px) {
  .servant-dialog[open] {
    padding: 0 0.75rem;
  }

  .servant-dialog-box {
    padding: 1.1rem;
    max-height: calc(100dvh - 2rem);
    overflow-y: auto;
  }
}

@media (pointer: coarse) {
  .servant-dialog-x {
    min-width: 44px;
    min-height: 44px;
  }

  .servant-dialog-actions button {
    min-height: 44px;
  }
}
</style>
