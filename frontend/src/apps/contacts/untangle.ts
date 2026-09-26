// Crossing reduction for the relations graph. A force layout settles wherever
// its seed leads, often with a branch folded back over its neighbours. Every
// branch hanging off a contact (the nodes that reach the rest only through it:
// a leaf, a chain, a small cycle) is tried at other angles around that contact,
// the opposite side included, and kept wherever it crosses fewer edges.
// ponytail: greedy, straight segments stand in for the shallow arcs, a few
// rounds max; enough for an address book, a proper planarity pass would be
// the upgrade if graphs ever reach thousands of relations.

export interface Point {
  id: string
  x: number
  y: number
}
export interface Link {
  from: string
  to: string
}

const ROTATIONS = [1, 2, 3, 4, 5, 6, 7].map(step => (step * Math.PI) / 4)

// Proper intersection of segments ab and cd (shared endpoints do not count).
function segmentsCross(a: Point, b: Point, c: Point, d: Point): boolean {
  if (a === c || a === d || b === c || b === d) return false
  const orient = (p: Point, q: Point, r: Point) =>
    Math.sign((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x))
  return (
    orient(a, b, c) * orient(a, b, d) < 0 &&
    orient(c, d, a) * orient(c, d, b) < 0
  )
}

// Crossings involving at least one of `subset` (every crossing when omitted).
export function crossingCount(
  nodes: Map<string, Point>,
  links: Link[],
  subset: Link[] = links
): number {
  const inSubset = new Set(subset)
  let count = 0
  for (const link of subset) {
    const a = nodes.get(link.from)!
    const b = nodes.get(link.to)!
    for (const other of links) {
      if (other === link) continue
      // A pair inside the subset is met twice; count it once.
      if (inSubset.has(other) && links.indexOf(other) < links.indexOf(link))
        continue
      if (segmentsCross(a, b, nodes.get(other.from)!, nodes.get(other.to)!))
        count++
    }
  }
  return count
}

// Groups of nodes that hang off `pivot`: the connected pieces left once it is
// removed, minus the largest one (the rest of the graph stays put).
function branchesOf(pivot: string, adjacency: Map<string, string[]>) {
  const seen = new Set([pivot])
  const pieces: string[][] = []
  for (const start of adjacency.get(pivot) || []) {
    if (seen.has(start)) continue
    const piece: string[] = []
    const queue = [start]
    seen.add(start)
    while (queue.length) {
      const current = queue.shift()!
      piece.push(current)
      for (const next of adjacency.get(current) || []) {
        if (!seen.has(next)) {
          seen.add(next)
          queue.push(next)
        }
      }
    }
    pieces.push(piece)
  }
  pieces.sort((a, b) => b.length - a.length)
  return pieces.slice(1)
}

export function untangle(nodes: Map<string, Point>, links: Link[]): void {
  const adjacency = new Map<string, string[]>()
  for (const link of links) {
    adjacency.set(link.from, [...(adjacency.get(link.from) || []), link.to])
    adjacency.set(link.to, [...(adjacency.get(link.to) || []), link.from])
  }

  for (let round = 0; round < 4; round++) {
    let improved = false
    for (const [pivotId, pivot] of nodes) {
      for (const branch of branchesOf(pivotId, adjacency)) {
        const members = new Set(branch)
        const touched = links.filter(
          link => members.has(link.from) || members.has(link.to)
        )
        let best = crossingCount(nodes, links, touched)
        if (best === 0) continue
        const origin = branch.map(id => ({ ...nodes.get(id)! }))
        let bestAngle = 0
        for (const angle of ROTATIONS) {
          rotate(branch, origin, pivot, angle, nodes)
          const count = crossingCount(nodes, links, touched)
          if (count < best) {
            best = count
            bestAngle = angle
          }
        }
        rotate(branch, origin, pivot, bestAngle, nodes)
        if (bestAngle) improved = true
      }
    }
    if (!improved) break
  }
}

function rotate(
  branch: string[],
  origin: Point[],
  pivot: Point,
  angle: number,
  nodes: Map<string, Point>
) {
  const cos = Math.cos(angle)
  const sin = Math.sin(angle)
  branch.forEach((id, i) => {
    const node = nodes.get(id)!
    const dx = origin[i].x - pivot.x
    const dy = origin[i].y - pivot.y
    node.x = pivot.x + dx * cos - dy * sin
    node.y = pivot.y + dx * sin + dy * cos
  })
}
