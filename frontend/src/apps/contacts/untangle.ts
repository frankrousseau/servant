// Crossing reduction for the relations graph. A force layout settles where its
// seed leads, and a branch often folds back over its neighbors. A branch of a
// contact is the set of nodes that reach the rest only through that contact: a
// leaf, a chain, a small cycle. This pass tries each branch at other angles
// around its contact, the opposite side included. It keeps the angle where the
// branch crosses fewer edges.
// ponytail: this pass is greedy. Straight segments replace the shallow arcs.
// It does a few rounds at most. That is sufficient for an address book. If
// graphs get to thousands of relations, the upgrade is a proper planarity pass.

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

// Finds if the segments ab and cd have a proper intersection. Shared endpoints
// do not count.
function segmentsCross(a: Point, b: Point, c: Point, d: Point): boolean {
  if (a === c || a === d || b === c || b === d) return false
  const orient = (p: Point, q: Point, r: Point) =>
    Math.sign((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x))
  return (
    orient(a, b, c) * orient(a, b, d) < 0 &&
    orient(c, d, a) * orient(c, d, b) < 0
  )
}

// Counts the crossings that include at least one link of `subset`. Without
// `subset`, it counts every crossing.
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
      // The loop meets a pair inside the subset twice. Count it once.
      if (inSubset.has(other) && links.indexOf(other) < links.indexOf(link))
        continue
      if (segmentsCross(a, b, nodes.get(other.from)!, nodes.get(other.to)!))
        count++
    }
  }
  return count
}

// Returns the groups of nodes that hang off `pivot`. These are the connected
// pieces that stay when you remove `pivot`, minus the largest one. The largest
// one is the rest of the graph, and it does not move.
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
