<script setup lang="ts">
import { computed, ref, watch } from 'vue'
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
}>()

// The date being edited: today by default, any heatmap cell on click
// (logging yesterday's forgotten guitar session is a first-class gesture).
const editDate = ref(props.today)
watch(
  () => props.today,
  t => {
    editDate.value = t
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
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return `${r}, ${g}, ${b}`
})

const ALPHAS = [0, 0.18, 0.38, 0.62, 0.9]

function cellStyle(level: number): Record<string, string> {
  if (!level) return {}
  return { background: `rgba(${rgb.value}, ${ALPHAS[level]})` }
}

// Entry trackers are computed from existing entries: no editing gestures.
const readOnly = computed(() => props.tracker.type === 'entry')

const statLabel = computed(() => {
  const t = props.tracker
  if (t.type === 'check') return `streak ${streak(props.byDate, props.today)}d`
  if (t.type === 'count' || t.type === 'entry') {
    const sum = sumLastDays(props.byDate, props.today, 7)
    const rounded = Math.round(sum * 100) / 100
    return `7d: ${rounded}${t.unit ? ' ' + t.unit : ''}`
  }
  const last = lastValue(props.byDate, props.today)
  return last == null ? 'no data' : `last: ${last}${t.unit ? ' ' + t.unit : ''}`
})

function toggleCheck() {
  emit('set', editDate.value, editValue.value > 0 ? 0 : 1)
}

function increment(delta: number) {
  emit('set', editDate.value, Math.max(0, editValue.value + delta))
}

function saveValue() {
  const v = parseFloat(valueDraft.value.replace(',', '.'))
  if (Number.isFinite(v)) emit('set', editDate.value, v)
}

function cellTitle(date: string, value: number): string {
  const unit = props.tracker.unit ? ` ${props.tracker.unit}` : ''
  return `${date}: ${value}${unit}`
}

function onCellClick(date: string) {
  if (!readOnly.value) editDate.value = date
}

// Explicit way to fix a previous day (the heatmap cells do it too).
function onDatePick(e: Event) {
  const v = (e.target as HTMLInputElement).value
  if (v && v <= props.today) editDate.value = v
}
</script>

<template>
  <section class="tk-card">
    <div class="tk-head">
      <span class="tk-swatch" :style="{ background: tracker.color }"></span>
      <h2 class="tk-name">{{ tracker.name }}</h2>
      <span class="tk-stat">{{ statLabel }}</span>
      <button class="tk-del" title="Delete tracker" @click="emit('remove')">
        ×
      </button>
    </div>

    <div v-if="readOnly" class="tk-controls">
      <span class="tk-auto">
        {{ tracker.agg === 'sum' ? `sum of ${tracker.field}` : 'count' }} of
        {{ tracker.entryKind }} entries
      </span>
    </div>

    <div v-else class="tk-controls">
      <span v-if="editDate !== today" class="tk-editing">
        {{ editDate }}
        <button class="tk-back" @click="editDate = today">back to today</button>
      </span>

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

      <input
        class="tk-date-pick"
        type="date"
        title="Fix a previous day"
        :value="editDate"
        :max="today"
        @change="onDatePick"
      />
    </div>

    <div class="tk-heatmap" role="img" :aria-label="`${tracker.name} history`">
      <div v-for="(week, w) in heatWeeks" :key="w" class="tk-week">
        <template v-for="(cell, d) in week" :key="d">
          <button
            v-if="cell"
            class="tk-cell"
            :class="{ 'tk-cell--edit': !readOnly && cell.date === editDate }"
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
.tk-stat {
  margin-left: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  color: var(--text-muted);
}
.tk-editing {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.75rem;
  color: var(--warning);
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
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
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 1.1rem;
  font-weight: 600;
  min-width: 2.2em;
  text-align: center;
}
.tk-date-pick {
  margin-left: auto;
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
