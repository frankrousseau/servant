<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue'
import { AlertTriangle } from 'lucide-vue-next'

import { useConfirm } from '../composables/useConfirm'

const { visible, title, message, confirmLabel, danger, resolve } = useConfirm()

const dialog = ref<HTMLDialogElement | null>(null)

// The dialog element is only hit by clicks on its backdrop: the padding
// lives on the inner .confirm-modal wrapper, so any click inside the box
// targets that wrapper instead.
function onDialogClick(event: MouseEvent) {
  if (event.target === dialog.value) resolve(false)
}

// Escape is handled at the document level (capture phase) instead of the
// dialog's native cancel event so it can stop propagation: an underlying
// MediaViewer's document-level Escape handler must not also fire and close
// the layer beneath the confirm. preventDefault suppresses native cancel,
// which would otherwise close the dialog a second time.
function onKeydown(event: KeyboardEvent) {
  if (!visible.value) return
  if (event.key === 'Escape') {
    event.preventDefault()
    event.stopPropagation()
    resolve(false)
  }
}

// flush: 'post' so showModal() runs after the autofocus attributes have
// been re-rendered for this ask(); the browser reads them at open time.
watch(
  visible,
  isVisible => {
    if (isVisible) {
      document.addEventListener('keydown', onKeydown, true)
      dialog.value?.showModal()
    } else {
      document.removeEventListener('keydown', onKeydown, true)
      dialog.value?.close()
    }
  },
  { flush: 'post' }
)

onUnmounted(() => document.removeEventListener('keydown', onKeydown, true))
</script>

<template>
  <Teleport to="body">
    <dialog
      ref="dialog"
      class="confirm-dialog"
      role="alertdialog"
      aria-labelledby="confirm-title"
      aria-describedby="confirm-message"
      @click="onDialogClick"
      @close="resolve(false)"
    >
      <div class="confirm-modal">
        <div class="confirm-icon" :class="{ 'confirm-icon--danger': danger }">
          <AlertTriangle :size="24" />
        </div>
        <h3 id="confirm-title" class="confirm-title">{{ title }}</h3>
        <p id="confirm-message" class="confirm-message">{{ message }}</p>
        <div class="confirm-actions">
          <button
            class="confirm-btn confirm-btn--cancel"
            :autofocus="danger"
            @click="resolve(false)"
          >
            Cancel
          </button>
          <button
            class="confirm-btn"
            :class="danger ? 'confirm-btn--danger' : 'confirm-btn--primary'"
            :autofocus="!danger"
            @click="resolve(true)"
          >
            {{ confirmLabel }}
          </button>
        </div>
      </div>
    </dialog>
  </Teleport>
</template>

<style scoped>
/* The <dialog> is a bare, transparent frame in the top layer (no z-index
   needed); the visible box is the inner wrapper. */
.confirm-dialog {
  padding: 0;
  border: none;
  background: transparent;
  width: 100%;
  max-width: 380px;
}

.confirm-dialog::backdrop {
  background: rgba(0, 0, 0, 0.6);
}

/* Opening fade; closing is instant (display transitions would need
   allow-discrete for little gain). */
.confirm-dialog,
.confirm-dialog::backdrop {
  opacity: 1;
  transition: opacity 0.15s;
}

@starting-style {
  .confirm-dialog[open],
  .confirm-dialog[open]::backdrop {
    opacity: 0;
  }
}

.confirm-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  text-align: center;
}

.confirm-icon {
  width: 48px;
  height: 48px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 0 auto 1rem;
  background: rgba(var(--primary-rgb), 0.12);
  color: var(--primary);
}

.confirm-icon--danger {
  background: color-mix(in srgb, var(--danger) 12%, transparent);
  color: var(--danger);
}

.confirm-title {
  margin: 0 0 0.5rem;
  font-size: 1.1rem;
}

.confirm-message {
  color: var(--text-muted);
  font-size: 0.9rem;
  margin: 0 0 1.25rem;
  line-height: 1.4;
}

.confirm-actions {
  display: flex;
  gap: 0.5rem;
}

.confirm-btn {
  flex: 1;
  padding: 0.6rem 1rem;
  border-radius: 8px;
  font-size: 0.9rem;
  font-weight: 500;
  cursor: pointer;
  transition:
    background 0.15s,
    border-color 0.15s;
}

.confirm-btn--cancel {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
}

.confirm-btn--cancel:hover {
  border-color: var(--text-muted);
}

.confirm-btn--danger {
  background: var(--danger);
  border: 1px solid var(--danger);
  color: var(--primary-contrast);
}

.confirm-btn--danger:hover {
  background: var(--danger-hover);
  border-color: var(--danger-hover);
}

.confirm-btn--primary {
  background: var(--primary);
  border: 1px solid var(--primary);
  color: var(--primary-contrast);
}

.confirm-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}
</style>
