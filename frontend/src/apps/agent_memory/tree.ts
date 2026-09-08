// Turns flat `path`s (memory/<project>/file, skills/<tool>/<name>/file,
// rules/<project>/file) into the nested tree the app renders.

export interface MemoryFile {
  id: string
  path: string
  project: string
  tool: string
  sha256: string
  size: number
  updated_at: string
  body?: string
}

export interface TreeNode {
  name: string
  path: string
  children: TreeNode[]
  file?: MemoryFile
}

const ROOTS: Record<string, string> = {
  memory: 'Memory',
  skills: 'Skills',
  rules: 'Rules'
}

export function buildTree(files: MemoryFile[]): TreeNode[] {
  const roots: TreeNode[] = Object.keys(ROOTS).map(key => ({
    name: ROOTS[key],
    path: key,
    children: []
  }))

  for (const memoryFile of files) {
    const segments = memoryFile.path.split('/')
    const node = roots.find(root => root.path === segments[0])
    if (!node) continue
    let current: TreeNode = node
    for (let i = 1; i < segments.length - 1; i++) {
      const path = segments.slice(0, i + 1).join('/')
      let child: TreeNode | undefined = current.children.find(
        candidate => candidate.path === path
      )
      if (!child) {
        child = { name: segments[i], path, children: [] }
        current.children.push(child)
      }
      current = child
    }
    current.children.push({
      name: segments[segments.length - 1],
      path: memoryFile.path,
      children: [],
      file: memoryFile
    })
  }

  return roots.filter(root => root.children.length > 0).map(sortNode)
}

function sortNode(node: TreeNode): TreeNode {
  node.children.sort((a, b) => {
    const aFolder = a.file ? 1 : 0
    const bFolder = b.file ? 1 : 0
    return aFolder - bFolder || a.name.localeCompare(b.name)
  })
  node.children.forEach(sortNode)
  return node
}
