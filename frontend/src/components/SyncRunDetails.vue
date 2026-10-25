<script setup lang="ts">
import { computed } from 'vue'
import { Check, Copy } from 'lucide-vue-next'

import KindIcon from './KindIcon.vue'

import { useCopyFeedback } from '../composables/useCopyFeedback'
import { formatTime } from '../lib/datetime'
import { entryRoute } from '../lib/entryRoute'
import { kindLabel } from '../lib/kind'
import type { SyncLogDetails } from '../types'

// What one sync run did, in the order a reader asks: where it broke, what
// came in, over which calls, and what the connector said along the way.
// Only the sections with something to show render.
const props = defineProps<{
  details: SyncLogDetails
  // New entries of the run: the details list 20 of them at most
  newCount: number
}>()

const { copiedId, copy } = useCopyFeedback()

const newEntries = computed(() =>
  (props.details.new_entries ?? []).map(entry => ({
    id: entry.id,
    kind: entry.kind,
    label: entry.title || 'Untitled',
    to: entryRoute(entry)
  }))
)
const moreNew = computed(() => props.newCount - newEntries.value.length)

const kinds = computed(() =>
  Object.entries(props.details.kinds ?? {})
    .sort((a, b) => b[1] - a[1])
    .map(([kind, count]) => ({ kind, count, label: kindLabel(kind) }))
)

const calls = computed(() =>
  (props.details.http ?? []).map((call, i) => ({
    key: i,
    method: call.method,
    url: `${call.host}${call.path}`,
    status: call.status ?? (call.error ? 'error' : '-'),
    error: call.error,
    failed: Boolean(call.error) || (call.status ?? 0) >= 400,
    duration: `${call.ms} ms`
  }))
)

const lines = computed(() =>
  (props.details.logs ?? []).map((line, i) => ({
    key: i,
    level: line.level,
    message: line.message,
    time: formatTime(line.at, {
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    })
  }))
)

const quiet = computed(
  () =>
    !props.details.stacktrace &&
    !newEntries.value.length &&
    !kinds.value.length &&
    !calls.value.length &&
    !lines.value.length
)
</script>

<template>
  <div class="run-details">
    <section v-if="details.stacktrace" class="run-section">
      <h3 class="run-title">Stack trace</h3>
      <details class="run-stack">
        <summary>Show the stack trace</summary>
        <pre>{{ details.stacktrace }}</pre>
      </details>
      <button
        type="button"
        class="small ghost run-copy"
        @click="copy(details.stacktrace ?? '', 'stack')"
      >
        <Check v-if="copiedId === 'stack'" :size="14" />
        <Copy v-else :size="14" />
        {{ copiedId === 'stack' ? 'Copied' : 'Copy the stack trace' }}
      </button>
    </section>

    <section v-if="newEntries.length" class="run-section">
      <h3 class="run-title">New entries</h3>
      <ul class="run-entries">
        <li v-for="entry in newEntries" :key="entry.id">
          <RouterLink :to="entry.to" class="run-entry">
            <KindIcon :kind="entry.kind" :size="14" />
            <span class="run-entry-title">{{ entry.label }}</span>
          </RouterLink>
        </li>
      </ul>
      <p v-if="moreNew > 0" class="run-more">+ {{ moreNew }} more</p>
    </section>

    <section v-if="kinds.length" class="run-section">
      <h3 class="run-title">By kind</h3>
      <ul class="run-kinds">
        <li v-for="item in kinds" :key="item.kind" class="run-kind">
          <KindIcon :kind="item.kind" :size="14" />
          <span>{{ item.label }}</span>
          <span class="run-count">{{ item.count }}</span>
        </li>
      </ul>
    </section>

    <section v-if="calls.length" class="run-section">
      <h3 class="run-title">HTTP calls</h3>
      <div class="table-scroll">
        <table class="run-calls">
          <thead>
            <tr>
              <th>Status</th>
              <th>Method</th>
              <th>Host and path</th>
              <th>Time</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="call in calls"
              :key="call.key"
              :class="{ 'run-call--failed': call.failed }"
            >
              <td>{{ call.status }}</td>
              <td>{{ call.method }}</td>
              <td class="run-call-url">
                {{ call.url }}
                <span v-if="call.error" class="run-call-error">{{
                  call.error
                }}</span>
              </td>
              <td>{{ call.duration }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-if="details.http_omitted" class="run-more">
        + {{ details.http_omitted }} more calls, not kept
      </p>
    </section>

    <section v-if="lines.length" class="run-section">
      <h3 class="run-title">Log</h3>
      <ol class="run-log">
        <li
          v-for="line in lines"
          :key="line.key"
          class="run-line"
          :class="`run-line--${line.level}`"
        >
          <span class="run-line-time">{{ line.time }}</span>
          <span class="run-line-level">{{ line.level }}</span>
          <span class="run-line-message">{{ line.message }}</span>
        </li>
      </ol>
      <p v-if="details.logs_omitted" class="run-more">
        + {{ details.logs_omitted }} more lines, not kept
      </p>
    </section>

    <p v-if="quiet" class="run-more">
      This run made no HTTP call and logged nothing.
    </p>
  </div>
</template>

<style scoped>
.run-details {
  display: flex;
  flex-direction: column;
  gap: 1rem;
  padding: 0.75rem 0 0.25rem;
}

.run-title {
  margin: 0 0 0.4rem;
  font-family: var(--font-display);
  font-weight: 400;
  font-size: var(--text-sm);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-muted);
}

.run-more {
  margin: 0.35rem 0 0;
  font-size: var(--text-sm);
  color: var(--text-muted);
}

/* ----- Stack trace ----- */

.run-stack summary {
  cursor: pointer;
  font-size: var(--text-sm);
  color: var(--text-muted);
}

.run-stack pre {
  margin-top: 0.5rem;
  padding: 0.75rem;
  max-height: 20rem;
  overflow: auto;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  white-space: pre;
}

.run-copy {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  margin-top: 0.5rem;
}

/* ----- New entries and kinds ----- */

.run-entries,
.run-kinds {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.run-entry,
.run-kind {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-width: 0;
}

.run-entry-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.run-count {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  color: var(--text-muted);
}

/* ----- HTTP calls ----- */

.run-calls {
  font-size: var(--text-sm);
}

.run-calls td {
  font-family: var(--font-mono);
  white-space: nowrap;
}

.run-calls .run-call-url {
  white-space: normal;
  word-break: break-all;
}

.run-call-error {
  display: block;
  color: var(--danger);
}

.run-call--failed td:first-child {
  color: var(--danger);
}

/* ----- Log ----- */

.run-log {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  font-family: var(--font-mono);
  font-size: var(--text-sm);
}

.run-line {
  display: flex;
  gap: 0.75rem;
}

.run-line-time,
.run-line-level {
  flex-shrink: 0;
  color: var(--text-muted);
}

.run-line-message {
  min-width: 0;
  overflow-wrap: anywhere;
}

.run-line--warning .run-line-level {
  color: var(--warning);
}

.run-line--error .run-line-level,
.run-line--critical .run-line-level {
  color: var(--danger);
}
</style>
