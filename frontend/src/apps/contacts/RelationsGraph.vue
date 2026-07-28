<script setup lang="ts">
import { computed } from 'vue'
import type { Entry } from '../types'
import { relationLabel, relationsOf } from './relations'

// The address book as a graph: contacts are nodes, declared relations are
// edges. Relations to the me-contact are left out, everyone has one.
// ponytail: static layout computed once per data change (deterministic
// golden-angle seed + a fixed force relaxation), no pan/zoom; revisit if a
// network outgrows one screen.

const props = defineProps<{ contacts: Entry[]; meId: string | null }>()
const emit = defineEmits<{ select: [id: string] }>()

const W = 900
const H = 620

const nameOf = (e: Entry) =>
  (
    (e.data.display_name as string) ||
    (e.title || '').split(/ - | — /)[0] ||
    ''
  ).trim() || 'Unnamed'

// Same hash as the avatar tint, so a contact keeps its color here.
function hueOf(name: string): number {
  let h = 0
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360
  return h
}

interface Node {
  id: string
  name: string
  hue: number
  x: number
  y: number
}
interface Edge {
  a: string
  b: string
  type: string
}

const graph = computed(() => {
  const byId = new Map(props.contacts.map(c => [c.id, c]))
  const edges: Edge[] = []
  const seen = new Set<string>()
  for (const c of props.contacts) {
    if (c.id === props.meId) continue
    for (const r of relationsOf(c)) {
      if (r.contact_id === props.meId || !byId.has(r.contact_id)) continue
      const key =
        c.id < r.contact_id
          ? `${c.id}|${r.contact_id}`
          : `${r.contact_id}|${c.id}`
      if (seen.has(key)) continue
      seen.add(key)
      edges.push({ a: c.id, b: r.contact_id, type: r.type })
    }
  }

  const ids = [...new Set(edges.flatMap(e => [e.a, e.b]))]
  const nodes = new Map<string, Node>()
  ids.forEach((id, i) => {
    const name = nameOf(byId.get(id)!)
    const angle = i * 2.399963
    const radius = 90 + 200 * Math.sqrt(i / Math.max(ids.length - 1, 1))
    nodes.set(id, {
      id,
      name,
      hue: hueOf(name),
      x: W / 2 + radius * Math.cos(angle),
      y: H / 2 + radius * Math.sin(angle) * 0.72
    })
  })

  // Fixed-step relaxation: pair repulsion, edge springs, light centering.
  const arr = [...nodes.values()]
  for (let iter = 0; iter < 150; iter++) {
    for (let i = 0; i < arr.length; i++) {
      for (let j = i + 1; j < arr.length; j++) {
        const a = arr[i]
        const b = arr[j]
        const dx = a.x - b.x
        const dy = a.y - b.y
        const d2 = dx * dx + dy * dy || 1
        const d = Math.sqrt(d2)
        const f = 2600 / d2
        a.x += (dx / d) * f
        a.y += (dy / d) * f
        b.x -= (dx / d) * f
        b.y -= (dy / d) * f
      }
    }
    for (const e of edges) {
      const a = nodes.get(e.a)!
      const b = nodes.get(e.b)!
      const dx = b.x - a.x
      const dy = b.y - a.y
      const d = Math.sqrt(dx * dx + dy * dy) || 1
      const f = (d - 110) * 0.02
      a.x += (dx / d) * f
      a.y += (dy / d) * f
      b.x -= (dx / d) * f
      b.y -= (dy / d) * f
    }
    for (const n of arr) {
      n.x += (W / 2 - n.x) * 0.01
      n.y += (H / 2 - n.y) * 0.01
    }
  }
  for (const n of arr) {
    n.x = Math.min(W - 70, Math.max(70, n.x))
    n.y = Math.min(H - 45, Math.max(45, n.y))
  }

  return { nodes: arr, byId: nodes, edges }
})

const NODE_R = 14

// Edge endpoints pulled back to the circle borders, so lines never run
// under the nodes they connect.
function edgeEnds(e: Edge) {
  const a = graph.value.byId.get(e.a)!
  const b = graph.value.byId.get(e.b)!
  const dx = b.x - a.x
  const dy = b.y - a.y
  const d = Math.sqrt(dx * dx + dy * dy) || 1
  const off = NODE_R + 3
  if (d <= off * 2) return { x1: a.x, y1: a.y, x2: a.x, y2: a.y }
  return {
    x1: a.x + (dx / d) * off,
    y1: a.y + (dy / d) * off,
    x2: b.x - (dx / d) * off,
    y2: b.y - (dy / d) * off
  }
}
</script>

<template>
  <div class="rg">
    <p v-if="!graph.edges.length" class="rg-empty">
      No relations between contacts yet. Link people from their card (relations
      to you are left out on purpose).
    </p>
    <svg
      v-else
      class="rg-svg"
      :viewBox="`0 0 ${W} ${H}`"
      role="img"
      aria-label="Contact relations graph"
    >
      <line
        v-for="e in graph.edges"
        :key="`${e.a}|${e.b}`"
        class="rg-edge"
        v-bind="edgeEnds(e)"
      >
        <title>{{ relationLabel(e.type) }}</title>
      </line>
      <g
        v-for="n in graph.nodes"
        :key="n.id"
        class="rg-node"
        role="button"
        tabindex="0"
        @click="emit('select', n.id)"
        @keydown.enter="emit('select', n.id)"
      >
        <!-- Opaque underlay: edges passing by never show through the disc. -->
        <circle :cx="n.x" :cy="n.y" :r="NODE_R" class="rg-node-bg" />
        <circle
          :cx="n.x"
          :cy="n.y"
          :r="NODE_R"
          :fill="`hsla(${n.hue}, 55%, 60%, 0.22)`"
          :stroke="`hsl(${n.hue}, 45%, 55%)`"
        />
        <text class="rg-label" :x="n.x" :y="n.y + 28">{{ n.name }}</text>
      </g>
    </svg>
  </div>
</template>

<style scoped>
.rg {
  height: 100%;
  display: flex;
  flex-direction: column;
}
.rg-empty {
  color: var(--text-muted);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88rem;
  padding: 2.5rem 1rem;
  text-align: center;
}
.rg-svg {
  width: 100%;
  height: 100%;
  min-height: 0;
}
.rg-edge {
  stroke: var(--border);
  stroke-width: 1.2;
}
.rg-node-bg {
  fill: var(--bg-surface);
}
.rg-node {
  cursor: pointer;
}
.rg-node:hover circle,
.rg-node:focus-visible circle {
  stroke-width: 2.5;
}
.rg-node:focus-visible {
  outline: none;
}
.rg-label {
  fill: var(--text);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 11px;
  text-anchor: middle;
}
</style>
