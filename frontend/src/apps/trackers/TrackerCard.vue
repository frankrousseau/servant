<script setup lang="ts">
import { computed, ref, watch } from 'vue'

import DateInput from '../../components/DateInput.vue'

import { weekdayName } from '../../lib/datetime'

import {
  heatmapWeeks,
  lastValue,
  streak,
  sumLastDays,
  type Tracker
} from './trackers'

const props = withDefaults(
  defineProps<{
    tracker: Tracker
    byDate: Map<string, number>
    today: string
    weeks?: number
    windowEnd?: string
  }>(),
  { weeks: 16, windowEnd: '' }
)
const emit = defineEmits<{
  set: [date: string, value: number]
  remove: []
  open: []
}>()

// The date that the user edits: today by default, or the date of a heatmap
// cell on click. To log the forgotten guitar session of yesterday is a
// first-class gesture.
const editDate = ref(props.today)
watch(
  () => props.today,
  next => {
    editDate.value = next
  }
)

const editValue = computed(() => props.byDate.get(editDate.value) ?? 0)

const valueDraft = ref('')
watch(
  editDate,
  () => {
    valueDraft.value = editValue.value ? String(editValue.value) : ''
  },
  { immediate: true }
)

const heatWeeks = computed(() =>
  heatmapWeeks(
    props.byDate,
    props.today,
    props.tracker.type,
    props.weeks,
    props.windowEnd || props.today
  )
)

const rgb = computed(() => {
  const hex = props.tracker.color
  const red = parseInt(hex.slice(1, 3), 16)
  const green = parseInt(hex.slice(3, 5), 16)
  const blue = parseInt(hex.slice(5, 7), 16)
  return `${red}, ${green}, ${blue}`
})

const ALPHAS = [0, 0.18, 0.38, 0.62, 0.9]

function cellStyle(level: number): Record<string, string> {
  if (!level) return {}
  return { background: `rgba(${rgb.value}, ${ALPHAS[level]})` }
}

// Entry trackers are computed from existing entries: they have no edit
// gestures.
const readOnly = computed(() => props.tracker.type === 'entry')

// The selected cell in full text (the heatmap shows only the intensity).
const cellInfo = computed(() => {
  const value = editValue.value
  const label =
    props.tracker.type === 'check'
      ? value > 0
        ? 'done'
        : 'not done'
      : `${Math.round(value * 100) / 100}${props.tracker.unit ? ' ' + props.tracker.unit : ''}`
  return `${editDate.value} · ${label}`
})

const statLabel = computed(() => {
  const tracker = props.tracker
  if (tracker.type === 'check')
    return `streak ${streak(props.byDate, props.today)}d`
  if (tracker.type === 'count' || tracker.type === 'entry') {
    const sum = sumLastDays(props.byDate, props.today, 7)
    const rounded = Math.round(sum * 100) / 100
    return `7d: ${rounded}${tracker.unit ? ' ' + tracker.unit : ''}`
  }
  const last = lastValue(props.byDate, props.today)
  return last == null
    ? 'no data'
    : `last: ${last}${tracker.unit ? ' ' + tracker.unit : ''}`
})

function toggleCheck() {
  emit('set', editDate.value, editValue.value > 0 ? 0 : 1)
}

function increment(delta: number) {
  emit('set', editDate.value, Math.max(0, editValue.value + delta))
}

function saveValue() {
  const value = parseFloat(valueDraft.value.replace(',', '.'))
  if (Number.isFinite(value)) emit('set', editDate.value, value)
}

function cellTitle(date: string, value: number): string {
  const unit = props.tracker.unit ? ` ${props.tracker.unit}` : ''
  return `${weekdayName(date)} ${date}: ${value}${unit}`
}

function onCellClick(date: string) {
  editDate.value = date
}

// An explicit way to correct a previous day (the heatmap cells also do it).
function onDatePick(value: string) {
  if (value && value <= props.today) editDate.value = value
}
</script>

<template>
  <section class="tk-card">
    <div class="tk-head">
      <span class="tk-swatch" :style="{ background: tracker.color }"></span>
      <h2 class="tk-name">
        <button
          class="tk-name-btn"
          title="Weekly, monthly and yearly totals"
          @click="emit('open')"
        >
          {{ tracker.name }}
        </button>
      </h2>
      <span class="tk-stat">{{ statLabel }}</span>
      <button
        class="tk-del"
        title="Delete tracker"
        aria-label="Delete tracker"
        @click="emit('remove')"
      >
        ×
      </button>
    </div>

    <div v-if="readOnly" class="tk-controls">
      <span class="tk-auto">
        {{ tracker.agg === 'sum' ? `sum of ${tracker.field}` : 'count' }} of
        {{ tracker.entryKind }} entries
      </span>
      <span class="tk-cell-info">
        {{ cellInfo }}
        <button
          v-if="editDate !== today"
          class="tk-back"
          @click="editDate = today"
        >
          back to today
        </button>
      </span>
    </div>

    <div v-else class="tk-controls">
      <button
        v-if="tracker.type === 'check'"
        class="tk-toggle"
        :class="{ 'tk-toggle--on': editValue > 0 }"
        @click="toggleCheck"
      >
        {{ editValue > 0 ? '☑ done' : '☐ not yet' }}
      </button>

      <template v-else-if="tracker.type === 'count'">
        <button
          class="tk-step"
          :disabled="editValue <= 0"
          @click="increment(-1)"
        >
          −
        </button>
        <span class="tk-count"
          >{{ editValue
          }}<span v-if="tracker.unit" class="tk-unit">
            {{ tracker.unit }}</span
          ></span
        >
        <button class="tk-step" @click="increment(1)">+</button>
      </template>

      <form v-else class="tk-value-form" @submit.prevent="saveValue">
        <input
          v-model="valueDraft"
          class="tk-value-input"
          :placeholder="tracker.unit || 'value'"
        />
        <button type="submit" class="tk-step tk-set">set</button>
        <span v-if="tracker.unit" class="tk-unit">{{ tracker.unit }}</span>
      </form>

      <span class="tk-cell-info">
        {{ cellInfo }}
        <button
          v-if="editDate !== today"
          class="tk-back"
          @click="editDate = today"
        >
          back to today
        </button>
      </span>
      <DateInput
        class="tk-date-pick"
        title="Fix a previous day"
        :model-value="editDate"
        :max="today"
        @update:model-value="onDatePick"
      />
    </div>

    <div class="tk-heatmap" role="img" :aria-label="`${tracker.name} history`">
      <div
        v-for="(week, weekIndex) in heatWeeks"
        :key="weekIndex"
        class="tk-week"
      >
        <template v-for="(cell, dayIndex) in week" :key="dayIndex">
          <button
            v-if="cell"
            class="tk-cell"
            :class="{ 'tk-cell--edit': cell.date === editDate }"
            :style="cellStyle(cell.level)"
            :title="cellTitle(cell.date, cell.value)"
            @click="onCellClick(cell.date)"
          ></button>
          <span v-else class="tk-cell tk-cell--future"></span>
        </template>
      </div>
    </div>
  </section>
</template>

<style scoped>
.tk-card {
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--bg-surface);
  padding: 0.85rem 1rem;
}
.tk-head {
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
}
.tk-swatch {
  width: 10px;
  height: 10px;
  border-radius: 3px;
  flex-shrink: 0;
  align-self: center;
}
.tk-name {
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tk-name-btn {
  border: none;
  background: transparent;
  color: inherit;
  font: inherit;
  padding: 0;
  cursor: pointer;
}
.tk-name-btn:hover {
  text-decoration: underline;
}
.tk-stat {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--text-muted);
  flex-shrink: 0;
}
.tk-del {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  padding: 0 0.25rem;
  font-size: 1.15rem;
  flex-shrink: 0;
}
.tk-del:hover {
  color: var(--danger);
}

.tk-controls {
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin: 0.6rem 0 0.75rem;
  min-height: 34px;
}
.tk-auto {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--text-muted);
}
.tk-cell-info {
  margin-left: auto;
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--text-muted);
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  white-space: nowrap;
}
.tk-back {
  border: none;
  background: transparent;
  color: var(--text-muted);
  cursor: pointer;
  font-size: 0.72rem;
  text-decoration: underline;
  padding: 0;
}
.tk-back:hover {
  color: var(--text);
}
.tk-toggle {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-muted);
  padding: 0.35rem 0.9rem;
  border-radius: 8px;
  font-size: 0.9rem;
  cursor: pointer;
}
.tk-toggle--on {
  border-color: var(--primary);
  color: var(--primary);
  background: rgba(var(--primary-rgb), 0.1);
}
.tk-step {
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text);
  width: 34px;
  height: 34px;
  border-radius: 8px;
  font-size: 1.05rem;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.tk-step:hover:not(:disabled) {
  border-color: var(--primary);
  color: var(--primary);
}
.tk-step:disabled {
  opacity: 0.4;
  cursor: default;
}
.tk-set {
  width: auto;
  padding: 0 0.7rem;
  font-size: 0.85rem;
}
.tk-count {
  font-family: var(--font-mono);
  font-size: 1.1rem;
  font-weight: 600;
  min-width: 2.2em;
  text-align: center;
}
.tk-date-pick {
  width: 150px;
  padding: 0.3rem 0.5rem;
  font-size: 0.8rem;
}
.tk-unit {
  color: var(--text-muted);
  font-size: 0.78rem;
  font-weight: 400;
  padding-left: 0.35rem;
}
.tk-value-form {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.tk-value-input {
  width: 120px;
  padding: 0.35rem 0.6rem;
  font-size: 0.9rem;
}

.tk-heatmap {
  display: flex;
  gap: 3px;
  overflow-x: auto;
  padding-bottom: 2px;
}
.tk-week {
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.tk-cell {
  width: 11px;
  height: 11px;
  border-radius: 2px;
  border: none;
  padding: 0;
  background: var(--bg-hover);
  cursor: pointer;
  flex-shrink: 0;
}
.tk-cell:hover {
  outline: 1px solid var(--text-muted);
  outline-offset: 1px;
}
.tk-cell--edit {
  outline: 1px solid var(--text);
  outline-offset: 1px;
}
.tk-cell--future {
  background: transparent;
  cursor: default;
}
</style>
