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

// Connected components, largest first (BFS over the edge adjacency).
function componentsOf(ids: string[], edges: Edge[]): string[][] {
  const adj = new Map<string, string[]>()
  for (const e of edges) {
    adj.set(e.a, [...(adj.get(e.a) || []), e.b])
    adj.set(e.b, [...(adj.get(e.b) || []), e.a])
  }
  const seen = new Set<string>()
  const out: string[][] = []
  for (const id of ids) {
    if (seen.has(id)) continue
    const comp: string[] = []
    const queue = [id]
    seen.add(id)
    while (queue.length) {
      const cur = queue.shift()!
      comp.push(cur)
      for (const next of adj.get(cur) || []) {
        if (!seen.has(next)) {
          seen.add(next)
          queue.push(next)
        }
      }
    }
    out.push(comp)
  }
  return out.sort((a, b) => b.length - a.length)
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

  // Disconnected groups each get their own patch of canvas (grid cell) and
  // gravitate toward its center, so unrelated families never pile up.
  const comps = componentsOf(ids, edges)
  const cols = Math.ceil(Math.sqrt(comps.length))
  const rows = Math.ceil(comps.length / cols)
  const cellW = W / cols
  const cellH = H / rows
  const centers = new Map<string, { x: number; y: number }>()
  const nodes = new Map<string, Node>()
  comps.forEach((comp, ci) => {
    const cx = (ci % cols) * cellW + cellW / 2
    const cy = Math.floor(ci / cols) * cellH + cellH / 2
    const rmax = Math.max(40, Math.min(cellW, cellH) / 2 - 50)
    comp.forEach((id, i) => {
      const name = nameOf(byId.get(id)!)
      const angle = i * 2.399963
      const radius = rmax * Math.sqrt((i + 1) / comp.length)
      centers.set(id, { x: cx, y: cy })
      nodes.set(id, {
        id,
        name,
        hue: hueOf(name),
        x: cx + radius * Math.cos(angle),
        y: cy + radius * Math.sin(angle) * 0.85
      })
    })
  })

  // Fixed-step relaxation: pair repulsion, edge springs, per-group gravity.
  const arr = [...nodes.values()]
  for (let iter = 0; iter < 150; iter++) {
    for (let i = 0; i < arr.length; i++) {
      for (let j = i + 1; j < arr.length; j++) {
        const a = arr[i]
        const b = arr[j]
        const dx = a.x - b.x
        // The name sits under the disc, so a node is taller than it is wide
        // and vertical crowding is what actually collides: distance is
        // measured on a squashed axis, which spreads neighbours more in y.
        const dy = (a.y - b.y) * 1.6
        const d2 = dx * dx + dy * dy || 1
        const d = Math.sqrt(d2)
        const f = 3600 / d2
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
      const f = (d - 130) * 0.02
      a.x += (dx / d) * f
      a.y += (dy / d) * f
      b.x -= (dx / d) * f
      b.y -= (dy / d) * f
    }
    for (const n of arr) {
      const c = centers.get(n.id)!
      n.x += (c.x - n.x) * 0.02
      n.y += (c.y - n.y) * 0.02
    }
  }
  for (const n of arr) {
    n.x = Math.min(W - 70, Math.max(70, n.x))
    n.y = Math.min(H - 45, Math.max(45, n.y))
  }

  return { nodes: arr, byId: nodes, edges }
})

const NODE_R = 14

// Endpoint moved off a node's border along the tangent at that end, which for
// a quadratic curve points at the control point. Keeps the arc clear of the
// discs it connects.
function pullBack(n: Node, cx: number, cy: number, off: number) {
  const dx = cx - n.x
  const dy = cy - n.y
  const d = Math.sqrt(dx * dx + dy * dy) || 1
  return { x: n.x + (dx / d) * off, y: n.y + (dy / d) * off }
}

// Edges are shallow arcs, not straight lines: two relations leaving the same
// contact at a close angle would lie on top of each other, and a straight edge
// passing behind an unrelated node reads as attached to it. The bow side comes
// from the pair key, so it is stable across renders and neighbours bow apart.
function edgePath(e: Edge): string {
  const a = graph.value.byId.get(e.a)!
  const b = graph.value.byId.get(e.b)!
  const dx = b.x - a.x
  const dy = b.y - a.y
  const d = Math.sqrt(dx * dx + dy * dy) || 1
  const bow = Math.min(24, d * 0.12) * (hueOf(e.a + e.b) % 2 ? 1 : -1)
  const cx = (a.x + b.x) / 2 - (dy / d) * bow
  const cy = (a.y + b.y) / 2 + (dx / d) * bow
  const off = NODE_R + 3
  const start = pullBack(a, cx, cy, off)
  const end = pullBack(b, cx, cy, off)
  return `M ${start.x} ${start.y} Q ${cx} ${cy} ${end.x} ${end.y}`
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
      <path
        v-for="e in graph.edges"
        :key="`${e.a}|${e.b}`"
        class="rg-edge"
        :d="edgePath(e)"
      >
        <title>{{ relationLabel(e.type) }}</title>
      </path>
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
  fill: none;
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
  /* Halo: an edge running behind a name stays readable. */
  paint-order: stroke;
  stroke: var(--bg-surface);
  stroke-width: 3px;
  stroke-linejoin: round;
}
</style>
