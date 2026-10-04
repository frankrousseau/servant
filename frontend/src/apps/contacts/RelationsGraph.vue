<script setup lang="ts">
import { computed } from 'vue'
import type { Entry } from '../types'
import { relationLabel, relationsOf } from './relations'
import { untangle } from './untangle'

// The address book as a graph: the contacts are nodes, the declared relations
// are edges. The graph omits the relations to the me-contact, because each
// contact has one.
// ponytail: the layout is static, computed once for each data change (a
// deterministic golden-angle seed + a fixed force relaxation). The canvas
// sets its size to the laid-out graph, and the pane scrolls. As a result,
// growth costs space, never legibility. A collision pass makes sure that the
// discs and the names stay apart.

const props = defineProps<{ contacts: Entry[]; meId: string | null }>()
const emit = defineEmits<{ select: [id: string] }>()

const W = 900
const H = 620

const nameOf = (contact: Entry) =>
  (
    (contact.data.display_name as string) ||
    (contact.title || '').split(/ - | — /)[0] ||
    ''
  ).trim() || 'Unnamed'

// This is the same hash as the avatar tint, so a contact keeps its color here.
function hueOf(name: string): number {
  let hash = 0
  for (let i = 0; i < name.length; i++)
    hash = (hash * 31 + name.charCodeAt(i)) % 360
  return hash
}

interface Node {
  id: string
  name: string
  hue: number
  x: number
  y: number
}
interface Edge {
  from: string
  to: string
  type: string
}

// Returns the connected components, largest first. It does a BFS over the
// edge adjacency.
function componentsOf(ids: string[], edges: Edge[]): string[][] {
  const adj = new Map<string, string[]>()
  for (const edge of edges) {
    adj.set(edge.from, [...(adj.get(edge.from) || []), edge.to])
    adj.set(edge.to, [...(adj.get(edge.to) || []), edge.from])
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
  const byId = new Map(props.contacts.map(contact => [contact.id, contact]))
  const edges: Edge[] = []
  const seen = new Set<string>()
  for (const contact of props.contacts) {
    if (contact.id === props.meId) continue
    for (const relation of relationsOf(contact)) {
      if (relation.contact_id === props.meId || !byId.has(relation.contact_id))
        continue
      const key =
        contact.id < relation.contact_id
          ? `${contact.id}|${relation.contact_id}`
          : `${relation.contact_id}|${contact.id}`
      if (seen.has(key)) continue
      seen.add(key)
      edges.push({
        from: contact.id,
        to: relation.contact_id,
        type: relation.type
      })
    }
  }

  const ids = [...new Set(edges.flatMap(edge => [edge.from, edge.to]))]

  // Each disconnected group gets its own patch of canvas (a grid cell) and
  // gravitates toward the center of that cell. As a result, unrelated
  // families never pile up.
  const comps = componentsOf(ids, edges)
  const cols = Math.ceil(Math.sqrt(comps.length))
  const rows = Math.ceil(comps.length / cols)
  // The seed canvas grows with the population: approximately 12 labeled nodes
  // fit easily in the base size. The pane scrolls when the result is larger
  // than the pane.
  const roominess = Math.max(1, Math.sqrt(ids.length / 12))
  const cellW = (W * roominess) / cols
  const cellH = (H * roominess) / rows
  const centers = new Map<string, { x: number; y: number }>()
  const nodes = new Map<string, Node>()
  comps.forEach((comp, compIndex) => {
    const cx = (compIndex % cols) * cellW + cellW / 2
    const cy = Math.floor(compIndex / cols) * cellH + cellH / 2
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
  const placed = [...nodes.values()]
  for (let iter = 0; iter < 150; iter++) {
    for (let i = 0; i < placed.length; i++) {
      for (let j = i + 1; j < placed.length; j++) {
        const nodeA = placed[i]
        const nodeB = placed[j]
        const dx = nodeA.x - nodeB.x
        // The name is below the disc, so a node is taller than it is wide.
        // As a result, the real collisions are vertical. The code measures
        // the distance on a squashed axis, and this spreads the neighbors
        // more in y.
        const dy = (nodeA.y - nodeB.y) * 1.6
        const distSq = dx * dx + dy * dy || 1
        const dist = Math.sqrt(distSq)
        const force = 3600 / distSq
        nodeA.x += (dx / dist) * force
        nodeA.y += (dy / dist) * force
        nodeB.x -= (dx / dist) * force
        nodeB.y -= (dy / dist) * force
      }
    }
    for (const edge of edges) {
      const nodeA = nodes.get(edge.from)!
      const nodeB = nodes.get(edge.to)!
      const dx = nodeB.x - nodeA.x
      const dy = nodeB.y - nodeA.y
      const dist = Math.sqrt(dx * dx + dy * dy) || 1
      const force = (dist - 130) * 0.02
      nodeA.x += (dx / dist) * force
      nodeA.y += (dy / dist) * force
      nodeB.x -= (dx / dist) * force
      nodeB.y -= (dy / dist) * force
    }
    // A node that is on the relation of other contacts looks like a part of
    // that relation. The chords push unrelated nodes aside, and they move
    // their endpoints back a small distance. As a result, the layout makes
    // room and the edges do not go over the discs.
    for (const edge of edges) {
      const nodeA = nodes.get(edge.from)!
      const nodeB = nodes.get(edge.to)!
      for (const node of placed) {
        if (node.id === edge.from || node.id === edge.to) continue
        const abx = nodeB.x - nodeA.x
        const aby = nodeB.y - nodeA.y
        const lenSq = abx * abx + aby * aby || 1
        const t = Math.max(
          0,
          Math.min(
            1,
            ((node.x - nodeA.x) * abx + (node.y - nodeA.y) * aby) / lenSq
          )
        )
        const dx = node.x - (nodeA.x + abx * t)
        const dy = node.y - (nodeA.y + aby * t)
        const dist = Math.hypot(dx, dy)
        if (dist >= 44 || dist === 0) continue
        const push = (44 - dist) * 0.25
        node.x += (dx / dist) * push
        node.y += (dy / dist) * push
        nodeA.x -= (dx / dist) * push * 0.3
        nodeA.y -= (dy / dist) * push * 0.3
        nodeB.x -= (dx / dist) * push * 0.3
        nodeB.y -= (dy / dist) * push * 0.3
      }
    }
    for (const node of placed) {
      const center = centers.get(node.id)!
      node.x += (center.x - node.x) * 0.02
      node.y += (center.y - node.y) * 0.02
    }
  }

  // The forces settle where the seed leads, and sometimes a branch folds
  // over its neighbors. First, swing such branches around their contact.
  untangle(nodes, edges)

  // The forces attract but guarantee nothing. These passes give the
  // guarantee. First, separate every disc+name box. Then, go along the real
  // arcs and push each unrelated node clear of them. Repeat until the two
  // properties are true together.
  resolveCollisions(placed)
  let slots = fanSlots(edges, nodes)
  for (let round = 0; round < 8; round++) {
    let moved = false
    for (const edge of edges) {
      const arc = arcOf(edge, nodes, slots.get(pairKey(edge)) || 0)
      for (const node of placed) {
        if (node.id === edge.from || node.id === edge.to) continue
        let best = Infinity
        let bestX = 0
        let bestY = 0
        for (let step = 0; step <= 20; step++) {
          const t = step / 20
          const u = 1 - t
          const px =
            u * u * arc.start.x + 2 * u * t * arc.cx + t * t * arc.end.x
          const py =
            u * u * arc.start.y + 2 * u * t * arc.cy + t * t * arc.end.y
          const d = Math.hypot(px - node.x, py - node.y)
          if (d < best) {
            best = d
            bestX = px
            bestY = py
          }
        }
        if (best >= EDGE_CLEAR) continue
        moved = true
        if (best < 1) {
          // The node is exactly on the arc: push it off along the chord's
          // normal.
          const chordX = arc.end.x - arc.start.x
          const chordY = arc.end.y - arc.start.y
          const chordLen = Math.hypot(chordX, chordY) || 1
          node.x -= (chordY / chordLen) * (EDGE_CLEAR + 2)
          node.y += (chordX / chordLen) * (EDGE_CLEAR + 2)
        } else {
          const scale = (EDGE_CLEAR - best + 2) / best
          node.x += (node.x - bestX) * scale
          node.y += (node.y - bestY) * scale
        }
      }
    }
    if (!moved) break
    resolveCollisions(placed)
    slots = fanSlots(edges, nodes)
  }

  // The canvas fits the laid-out graph, and the graph does not fit the
  // canvas. Small networks stay small. Large networks scroll at full size.
  const PAD = 46
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  for (const node of placed) {
    minX = Math.min(minX, node.x - labelHalfW(node.name))
    maxX = Math.max(maxX, node.x + labelHalfW(node.name))
    minY = Math.min(minY, node.y - 18)
    maxY = Math.max(maxY, node.y + 34)
  }
  const view = placed.length
    ? {
        x: Math.round(minX - PAD),
        y: Math.round(minY - PAD),
        w: Math.round(maxX - minX + 2 * PAD),
        h: Math.round(maxY - minY + 2 * PAD)
      }
    : { x: 0, y: 0, w: W, h: H }

  return {
    nodes: placed,
    view,
    edges: edges.map(edge => ({
      key: pairKey(edge),
      label: relationLabel(edge.type),
      d: edgePath(edge, nodes, slots.get(pairKey(edge)) || 0)
    }))
  }
})

const NODE_R = 14
// Gap between two adjacent strokes in a fan, at the arc's widest point.
const BOW_STEP = 26
// Minimum distance from any point of an arc to an unrelated node's center.
const EDGE_CLEAR = NODE_R + 10
// A node's footprint: the disc plus its name 28px below, in 11px mono.
const BOX_HALF_H = 26
const labelHalfW = (name: string) => Math.max(NODE_R + 4, name.length * 3.3 + 4)

const pairKey = (edge: Edge) => `${edge.from}|${edge.to}`

// Separate the disc+name boxes that overlap, pair by pair. Move each pair
// along the axis where the smaller push is necessary. Continue until every
// label is readable.
function resolveCollisions(placed: Node[]) {
  for (let iter = 0; iter < 60; iter++) {
    let moved = false
    for (let i = 0; i < placed.length; i++) {
      for (let j = i + 1; j < placed.length; j++) {
        const nodeA = placed[i]
        const nodeB = placed[j]
        const overlapX =
          labelHalfW(nodeA.name) +
          labelHalfW(nodeB.name) +
          2 -
          Math.abs(nodeA.x - nodeB.x)
        const overlapY = 2 * BOX_HALF_H + 2 - Math.abs(nodeA.y - nodeB.y)
        if (overlapX <= 0 || overlapY <= 0) continue
        moved = true
        if (overlapX < overlapY) {
          const push = (overlapX / 2) * (nodeA.x <= nodeB.x ? -1 : 1)
          nodeA.x += push
          nodeB.x -= push
        } else {
          const push = (overlapY / 2) * (nodeA.y <= nodeB.y ? -1 : 1)
          nodeA.y += push
          nodeB.y -= push
        }
      }
    }
    if (!moved) break
  }
}

// The edges that leave one contact fan out and do not stack. Each edge takes
// a slot in the fan of each of its two endpoints. A fan is the incident
// edges, in the order of the angle at which they leave. The slot sets the
// direction and the distance of the bow of the arc. As a result, two
// relations from the same contact cannot share a stroke, even when their
// directions are almost the same. The middle edge of a fan stays straight.
function fanSlots(
  edges: Edge[],
  nodes: Map<string, Node>
): Map<string, number> {
  const incident = new Map<string, Edge[]>()
  for (const edge of edges) {
    incident.set(edge.from, [...(incident.get(edge.from) || []), edge])
    incident.set(edge.to, [...(incident.get(edge.to) || []), edge])
  }

  const slots = new Map<string, number>()
  for (const [id, list] of incident) {
    const origin = nodes.get(id)!
    const ranked = [...list].sort(
      (a, b) => leaveAngle(origin, a, nodes) - leaveAngle(origin, b, nodes)
    )
    ranked.forEach((edge, index) => {
      const slot = index - (ranked.length - 1) / 2
      // The arc's normal runs from -> to, so a slot read at the far end is
      // mirrored. The busier endpoint wins, because it is the most crowded.
      const signed = edge.from === id ? slot : -slot
      const key = pairKey(edge)
      if (Math.abs(signed) > Math.abs(slots.get(key) ?? 0)) {
        slots.set(key, signed)
      }
    })
  }
  return slots
}

function leaveAngle(
  origin: Node,
  edge: Edge,
  nodes: Map<string, Node>
): number {
  const other = nodes.get(edge.from === origin.id ? edge.to : edge.from)!
  return Math.atan2(other.y - origin.y, other.x - origin.x)
}

// Returns the endpoint, moved off the border of a node along the tangent at
// that end. For a quadratic curve, this tangent points at the control point.
// This keeps the arc clear of the discs that it connects. It also spreads
// the attachment points of a fan around the rim.
function pullBack(node: Node, cx: number, cy: number, off: number) {
  const dx = cx - node.x
  const dy = cy - node.y
  const dist = Math.sqrt(dx * dx + dy * dy) || 1
  return { x: node.x + (dx / dist) * off, y: node.y + (dy / dist) * off }
}

// Returns a shallow arc from disc to disc. A straight edge that goes behind
// an unrelated node looks attached to it. As a result, even a lone pair
// keeps the curve form (slot 0 bows by zero).
function arcOf(edge: Edge, nodes: Map<string, Node>, slot: number) {
  const nodeA = nodes.get(edge.from)!
  const nodeB = nodes.get(edge.to)!
  const dx = nodeB.x - nodeA.x
  const dy = nodeB.y - nodeA.y
  const dist = Math.sqrt(dx * dx + dy * dy) || 1
  // Short edges bow proportionally less. If not, the arc swells past its nodes.
  const bow = slot * Math.min(BOW_STEP, dist * 0.25)
  const cx = (nodeA.x + nodeB.x) / 2 - (dy / dist) * bow
  const cy = (nodeA.y + nodeB.y) / 2 + (dx / dist) * bow
  const off = NODE_R + 3
  return {
    cx,
    cy,
    start: pullBack(nodeA, cx, cy, off),
    end: pullBack(nodeB, cx, cy, off)
  }
}

function edgePath(edge: Edge, nodes: Map<string, Node>, slot: number): string {
  const { start, cx, cy, end } = arcOf(edge, nodes, slot)
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
      :width="graph.view.w"
      :height="graph.view.h"
      :viewBox="`${graph.view.x} ${graph.view.y} ${graph.view.w} ${graph.view.h}`"
      role="img"
      aria-label="Contact relations graph"
    >
      <path
        v-for="edge in graph.edges"
        :key="edge.key"
        class="rg-edge"
        :d="edge.d"
      >
        <title>{{ edge.label }}</title>
      </path>
      <g
        v-for="node in graph.nodes"
        :key="node.id"
        class="rg-node"
        role="button"
        tabindex="0"
        @click="emit('select', node.id)"
        @keydown.enter="emit('select', node.id)"
      >
        <!-- Opaque underlay: no edge that passes by shows through the disc. -->
        <circle :cx="node.x" :cy="node.y" :r="NODE_R" class="rg-node-bg" />
        <circle
          :cx="node.x"
          :cy="node.y"
          :r="NODE_R"
          :fill="`hsla(${node.hue}, 55%, 60%, 0.22)`"
          :stroke="`hsl(${node.hue}, 45%, 55%)`"
        />
        <text class="rg-label" :x="node.x" :y="node.y + 28">
          {{ node.name }}
        </text>
      </g>
    </svg>
  </div>
</template>

<style scoped>
/* The svg renders at its natural size. Margin auto centers a small graph.
   A large graph scrolls here and does not scale down to fit. */
.rg {
  height: 100%;
  display: flex;
  overflow: auto;
}
.rg-empty {
  color: var(--text-muted);
  font-family: var(--font-mono);
  font-size: 0.88rem;
  padding: 2.5rem 1rem;
  text-align: center;
  margin: auto;
}
.rg-svg {
  margin: auto;
  flex-shrink: 0;
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
  font-family: var(--font-mono);
  font-size: 11px;
  text-anchor: middle;
  /* Halo: a name stays readable when an edge goes behind it. */
  paint-order: stroke;
  stroke: var(--bg-surface);
  stroke-width: 3px;
  stroke-linejoin: round;
}
</style>
