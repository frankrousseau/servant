// Turns flat files into the tree that the app renders. There is one root for
// each harness (Claude Code, Cursor, Shared). Below it comes the section that
// the first segment of the path names (memory, skills, rules). Then come the
// other folders and the file.

export interface MemoryFile {
  id: string
  path: string
  project: string
  tool: string
  sha256: string
  size: number
  updated_at: string
  // The app sets this field. The agents apply it at their next pull.
  pending?: 'deleted' | 'modified' | null
  body?: string
}

export interface TreeNode {
  name: string
  path: string
  children: TreeNode[]
  file?: MemoryFile
}

const HARNESSES = [
  { key: 'claude', name: 'Claude Code' },
  { key: 'cursor', name: 'Cursor' },
  { key: 'shared', name: 'Shared' }
]

const SECTIONS: Record<string, string> = {
  memory: 'Memory',
  skills: 'Skills',
  rules: 'Rules'
}

export function buildTree(files: MemoryFile[]): TreeNode[] {
  const roots: TreeNode[] = HARNESSES.map(harness => ({
    name: harness.name,
    path: harness.key,
    children: []
  }))

  for (const memoryFile of files) {
    const root = roots.find(candidate => candidate.path === memoryFile.tool)
    const segments = memoryFile.path.split('/')
    const section = SECTIONS[segments[0]]
    if (!root || !section) continue
    // skills/<tool>/<name>/... repeats the harness that the root already names.
    const folders = segments.slice(segments[0] === 'skills' ? 2 : 1, -1)
    let current = childFolder(root, section, `${root.path}/${segments[0]}`)
    for (const folder of folders) {
      current = childFolder(current, folder, `${current.path}/${folder}`)
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

function childFolder(parent: TreeNode, name: string, path: string): TreeNode {
  let child = parent.children.find(candidate => candidate.path === path)
  if (!child) {
    child = { name, path, children: [] }
    parent.children.push(child)
  }
  return child
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
