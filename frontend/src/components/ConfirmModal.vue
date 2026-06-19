<script setup lang="ts">
import { useConfirm } from "../composables/useConfirm";
import { AlertTriangle } from "lucide-vue-next";

const { visible, title, message, confirmLabel, danger, resolve } = useConfirm();

function onOverlayClick(e: MouseEvent) {
  if (e.target === e.currentTarget) resolve(false);
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === "Escape") resolve(false);
}
</script>

<template>
  <Teleport to="body">
    <Transition name="confirm-fade">
      <div
        v-if="visible"
        class="confirm-overlay"
        @click="onOverlayClick"
        @keydown="onKeydown"
      >
        <div class="confirm-modal" role="alertdialog">
          <div class="confirm-icon" :class="{ 'confirm-icon--danger': danger }">
            <AlertTriangle :size="24" />
          </div>
          <h3 class="confirm-title">{{ title }}</h3>
          <p class="confirm-message">{{ message }}</p>
          <div class="confirm-actions">
            <button class="confirm-btn confirm-btn--cancel" @click="resolve(false)">
              Cancel
            </button>
            <button
              class="confirm-btn"
              :class="danger ? 'confirm-btn--danger' : 'confirm-btn--primary'"
              @click="resolve(true)"
              ref="confirmBtnRef"
            >
              {{ confirmLabel }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.confirm-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.6);
  z-index: 10000;
  display: flex;
  align-items: center;
  justify-content: center;
}

.confirm-modal {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 1.5rem;
  width: 100%;
  max-width: 380px;
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
  background: rgba(108, 140, 255, 0.12);
  color: var(--primary);
}

.confirm-icon--danger {
  background: rgba(240, 108, 108, 0.12);
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
  transition: background 0.15s, border-color 0.15s;
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
  color: #fff;
}

.confirm-btn--danger:hover {
  background: var(--danger-hover);
  border-color: var(--danger-hover);
}

.confirm-btn--primary {
  background: var(--primary);
  border: 1px solid var(--primary);
  color: #fff;
}

.confirm-btn--primary:hover {
  background: var(--primary-hover);
  border-color: var(--primary-hover);
}

.confirm-fade-enter-active,
.confirm-fade-leave-active {
  transition: opacity 0.15s;
}

.confirm-fade-enter-from,
.confirm-fade-leave-to {
  opacity: 0;
}
</style>
