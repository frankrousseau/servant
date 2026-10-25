<script setup lang="ts">
import { computed, ref } from 'vue'
import { Check, ChevronRight, Copy, LoaderCircle, X } from 'lucide-vue-next'

import SyncRunDetails from './SyncRunDetails.vue'

import { connectorLogDetails } from '../api/connectors'
import { useCopyFeedback } from '../composables/useCopyFeedback'
import { relativeTime } from '../lib/datetime'
import type { SyncLog, SyncLogDetails } from '../types'

// The run history of a source, one row per sync or file import. A finished
// row opens on what the run did (SyncRunDetails), fetched the first time it
// opens, then kept.
const props = defineProps<{
  connectorId: string
  logs: SyncLog[]
}>()

type DetailState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'ready'; details: SyncLogDetails | null }

const opened = ref(new Set<string>())
const loaded = ref(new Map<string, DetailState>())
const { copiedId, copy } = useCopyFeedback()

const rows = computed(() =>
  props.logs.map(log => ({
    log,
    expandable: log.status !== 'running',
    open: opened.value.has(log.id),
    outcome: outcome(log),
    callsFailed: log.http_failed_count
      ? `${log.http_failed_count} of ${log.http_count} calls failed`
      : '',
    when: relativeTime(log.started_at),
    duration: duration(log),
    detail: loaded.value.get(log.id)
  }))
)

// "12 new · 140 already known"; a failed run that brought nothing says it
// in its error instead
function outcome(log: SyncLog): string {
  if (log.status === 'running') return ''
  if (log.status === 'failed' && !log.fetched_count) return ''
  const parts = [log.entries_count ? `${log.entries_count} new` : 'Nothing new']
  if (log.known_count) parts.push(`${log.known_count} already known`)
  return parts.join(' · ')
}

function duration(log: SyncLog): string {
  if (!log.finished_at) return '-'
  const ms =
    new Date(log.finished_at).getTime() - new Date(log.started_at).getTime()
  if (ms < 1000) return `${ms}ms`
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60000).toFixed(1)}m`
}

async function toggle(log: SyncLog) {
  if (opened.value.has(log.id)) {
    opened.value.delete(log.id)
    return
  }
  opened.value.add(log.id)
  const known = loaded.value.get(log.id)
  if (known && known.status !== 'error') return

  loaded.value.set(log.id, { status: 'loading' })
  try {
    const details = await connectorLogDetails(props.connectorId, log.id)
    loaded.value.set(log.id, { status: 'ready', details })
  } catch {
    loaded.value.set(log.id, { status: 'error' })
  }
}
</script>

<template>
  <ul class="sync-history">
    <li v-for="row in rows" :key="row.log.id" class="sync-run">
      <div class="sync-run-head">
        <span
          class="sync-run-icon"
          :class="`sync-run-icon--${row.log.status}`"
          aria-hidden="true"
        >
          <Check v-if="row.log.status === 'completed'" :size="14" />
          <X v-else-if="row.log.status === 'failed'" :size="14" />
          <LoaderCircle v-else :size="14" class="sync-run-spin" />
        </span>
        <button
          v-if="row.expandable"
          type="button"
          class="sync-run-toggle"
          :aria-expanded="row.open"
          :aria-controls="`sync-run-${row.log.id}`"
          @click="toggle(row.log)"
        >
          <span class="sync-run-status">{{ row.log.status }}</span>
          <span v-if="row.outcome" class="sync-run-outcome">{{
            row.outcome
          }}</span>
          <span v-if="row.callsFailed" class="sync-run-badge">{{
            row.callsFailed
          }}</span>
          <ChevronRight :size="16" class="sync-run-chevron" />
        </button>
        <span v-else class="sync-run-status">{{ row.log.status }}</span>
        <span class="sync-run-time">
          <span>{{ row.when }}</span>
          <span>{{ row.duration }}</span>
        </span>
      </div>

      <p v-if="row.log.error" class="sync-run-error">
        <span class="sync-run-error-text">{{ row.log.error }}</span>
        <button
          type="button"
          class="sync-run-copy"
          :title="copiedId === row.log.id ? 'Copied!' : 'Copy error'"
          :aria-label="copiedId === row.log.id ? 'Copied' : 'Copy error'"
          @click="copy(row.log.error ?? '', row.log.id)"
        >
          <Check v-if="copiedId === row.log.id" :size="14" />
          <Copy v-else :size="14" />
        </button>
      </p>

      <div
        v-if="row.open"
        :id="`sync-run-${row.log.id}`"
        class="sync-run-details"
      >
        <p
          v-if="!row.detail || row.detail.status === 'loading'"
          class="sync-run-note"
        >
          Loading...
        </p>
        <p v-else-if="row.detail.status === 'error'" class="sync-run-note">
          The details of this run could not be loaded.
        </p>
        <SyncRunDetails
          v-else-if="row.detail.details"
          :details="row.detail.details"
          :new-count="row.log.entries_count"
        />
        <p v-else class="sync-run-note">
          Details are kept for the 50 most recent runs.
        </p>
      </div>
    </li>
  </ul>
</template>

<style scoped>
.sync-history {
  list-style: none;
  display: flex;
  flex-direction: column;
}

.sync-run {
  padding: 0.6rem 0;
  border-bottom: 1px solid var(--border);
}

.sync-run:last-child {
  border-bottom: none;
}

/* ----- Row ----- */

.sync-run-head {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.sync-run-icon {
  width: 26px;
  height: 26px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.sync-run-icon--completed {
  background: color-mix(in srgb, var(--success) 15%, transparent);
  color: var(--success);
}

.sync-run-icon--failed {
  background: color-mix(in srgb, var(--danger) 15%, transparent);
  color: var(--danger);
}

.sync-run-icon--running {
  background: rgba(var(--primary-rgb), 0.15);
  color: var(--primary);
}

.sync-run-spin {
  animation: sync-run-spin 1.2s linear infinite;
}

@keyframes sync-run-spin {
  to {
    transform: rotate(360deg);
  }
}

/* A plain row, not a painted button: the text and the chevron say it
   opens; hover and focus change the color only */
.sync-run-toggle {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.25rem 0.75rem;
  padding: 0.25rem 0;
  background: transparent;
  border: none;
  border-radius: 0;
  color: var(--text);
  text-align: left;
}

.sync-run-toggle:hover {
  background: transparent;
  color: var(--text);
}

.sync-run-status {
  font-weight: 500;
  text-transform: capitalize;
}

.sync-run-outcome {
  font-size: var(--text-sm);
  color: var(--text-muted);
}

.sync-run-badge {
  font-size: var(--text-sm);
  color: var(--danger);
}

.sync-run-chevron {
  margin-left: auto;
  color: var(--text-muted);
  transition: transform 0.15s;
}

.sync-run-toggle[aria-expanded='true'] .sync-run-chevron {
  transform: rotate(90deg);
}

.sync-run-time {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  font-size: var(--text-sm);
  color: var(--text-muted);
  white-space: nowrap;
}

/* ----- Error ----- */

.sync-run-error {
  display: flex;
  align-items: center;
  gap: 0.35rem;
  min-width: 0;
  margin: 0.25rem 0 0 calc(26px + 0.75rem);
}

.sync-run-error-text {
  font-family: var(--font-mono);
  font-size: var(--text-sm);
  color: var(--danger);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sync-run-copy {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 24px;
  height: 24px;
  padding: 0;
  background: transparent;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  color: var(--text-muted);
}

.sync-run-copy:hover {
  background: transparent;
  border-color: var(--primary);
  color: var(--primary);
}

/* ----- Details ----- */

.sync-run-details {
  margin-left: calc(26px + 0.75rem);
}

.sync-run-note {
  padding-top: 0.5rem;
  font-size: var(--text-sm);
  color: var(--text-muted);
}
</style>
