<script setup lang="ts">
// The loading / error / empty states of a list, one look everywhere, the
// content itself once there is some. The loading line is a polite status
// and the error an alert, so assistive tech announces both without the
// caller wiring any ARIA.
//
// <LoadState :state="loadState" :empty="!notes.length" what="notes" @retry="reload">
//   <NoteList :notes="notes" />
// </LoadState>
//
// `what` builds the default lines ("Loading notes…", "Failed to load
// notes.", "No notes yet."); the texts and the #empty slot override them.
export type LoadStatus = 'loading' | 'ready' | 'error'

const props = withDefaults(
  defineProps<{
    state: LoadStatus
    // Ready but nothing to show.
    empty?: boolean
    // Plural noun of what loads: "notes", "checklists".
    what: string
    loadingText?: string
    errorText?: string
    emptyText?: string
    // Shows a Retry button on error.
    retryable?: boolean
  }>(),
  {
    empty: false,
    loadingText: undefined,
    errorText: undefined,
    emptyText: undefined,
    retryable: false
  }
)
const emit = defineEmits<{ retry: [] }>()
</script>

<template>
  <p v-if="props.state === 'loading'" class="load-state" role="status">
    {{ loadingText ?? `Loading ${what}…` }}
  </p>
  <div
    v-else-if="props.state === 'error'"
    class="load-state load-state--error"
    role="alert"
  >
    <p class="load-state-line">{{ errorText ?? `Failed to load ${what}.` }}</p>
    <button
      v-if="retryable"
      type="button"
      class="load-state-retry"
      @click="emit('retry')"
    >
      Retry
    </button>
  </div>
  <div v-else-if="props.empty" class="load-state">
    <slot name="empty">
      <p class="load-state-line">{{ emptyText ?? `No ${what} yet.` }}</p>
    </slot>
  </div>
  <slot v-else />
</template>

<style scoped>
.load-state {
  margin: 0;
  padding: 2.5rem 1rem;
  text-align: center;
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

.load-state-line {
  margin: 0;
}

.load-state--error {
  color: var(--danger);
}

.load-state-retry {
  margin-top: 0.75rem;
}
</style>
