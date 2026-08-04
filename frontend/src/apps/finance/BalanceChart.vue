<script setup lang="ts">
import { computed } from 'vue'
import type { SnapshotPoint } from './finance'

// Step chart for balance history: balances are observations, so the value
// holds flat between two snapshots (no interpolation) and extends to today.

const props = defineProps<{
  points: SnapshotPoint[]
  endDate: string
  color?: string
}>()

const W = 600
const H = 150
const PAD_X = 4
const PAD_TOP = 14
const PAD_BOTTOM = 18

const dayMs = (date: string) => {
  const [year, month, day] = date.split('-').map(Number)
  return Date.UTC(year, month - 1, day)
}

const geometry = computed(() => {
  if (!props.points.length) return null
  const xs = props.points.map(point => dayMs(point.date))
  const x0 = xs[0]
  const x1 = Math.max(dayMs(props.endDate), xs[xs.length - 1])
  const span = Math.max(x1 - x0, 1)
  const values = props.points.map(point => point.amount)
  const lo = Math.min(...values)
  const hi = Math.max(...values)
  // Baseline at 0 when everything is positive and 0 is close enough to keep
  // proportions readable; otherwise fit the data so small variations on a
  // big balance stay visible.
  let min = lo > 0 && lo <= (hi - lo) * 4 ? 0 : lo
  let max = hi
  if (min === max) {
    min -= 1
    max += 1
  }
  const yPad = (max - min) * 0.08
  min -= yPad
  max += yPad

  const toX = (ms: number) => PAD_X + ((ms - x0) / span) * (W - 2 * PAD_X)
  const toY = (value: number) =>
    PAD_TOP + (1 - (value - min) / (max - min)) * (H - PAD_TOP - PAD_BOTTOM)

  let path = `M ${toX(xs[0]).toFixed(1)} ${toY(values[0]).toFixed(1)}`
  for (let i = 1; i < props.points.length; i++) {
    path += ` H ${toX(xs[i]).toFixed(1)} V ${toY(values[i]).toFixed(1)}`
  }
  path += ` H ${toX(x1).toFixed(1)}`

  const dots = props.points.map(point => ({
    cx: toX(dayMs(point.date)),
    cy: toY(point.amount),
    title: `${point.date}: ${point.amount.toLocaleString()}`
  }))

  return {
    d: path,
    dots,
    minLabel: Math.min(...values).toLocaleString(),
    maxLabel: Math.max(...values).toLocaleString(),
    fromLabel: props.points[0].date,
    toLabel: props.endDate
  }
})

const stroke = computed(() => props.color || 'var(--primary)')
</script>

<template>
  <div class="bc">
    <svg
      v-if="geometry"
      class="bc-svg"
      :viewBox="`0 0 ${W} ${H}`"
      role="img"
      aria-label="Balance history"
    >
      <path
        class="bc-line"
        :d="geometry.d"
        fill="none"
        :stroke="stroke"
        stroke-width="1.5"
      />
      <circle
        v-for="(dot, index) in geometry.dots"
        :key="index"
        class="bc-dot"
        :cx="dot.cx"
        :cy="dot.cy"
        r="2"
        :fill="stroke"
      >
        <title>{{ dot.title }}</title>
      </circle>
      <text class="bc-label" :x="PAD_X" y="9">{{ geometry.maxLabel }}</text>
      <text class="bc-label" :x="PAD_X" :y="H - PAD_BOTTOM + 12">
        {{ geometry.minLabel }}
      </text>
      <text class="bc-label bc-label--end" :x="W - PAD_X" :y="H - 4">
        {{ geometry.toLabel }}
      </text>
      <text class="bc-label" :x="PAD_X" :y="H - 4">
        {{ geometry.fromLabel }}
      </text>
    </svg>
    <p v-else class="bc-empty">No snapshots yet.</p>
  </div>
</template>

<style scoped>
.bc-svg {
  display: block;
  width: 100%;
  height: auto;
}
.bc-line {
  vector-effect: non-scaling-stroke;
}
.bc-dot {
  opacity: 0.9;
}
.bc-label {
  font-family: var(--font-mono);
  font-size: 9px;
  fill: var(--text-muted);
}
.bc-label--end {
  text-anchor: end;
}
.bc-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.85rem;
  padding: 1.5rem 0;
  margin: 0;
}
</style>
