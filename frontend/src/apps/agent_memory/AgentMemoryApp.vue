<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import MemoryTreeNode from './MemoryTreeNode.vue'

import { formatDateTime } from '../../lib/datetime'
import { renderMarkdown } from '../notes/render'
import { buildTree } from './tree'
import type { AppContext } from '../types'
import type { MemoryFile, TreeNode } from './tree'

const props = defineProps<{ ctx: AppContext }>()

const files = ref<MemoryFile[]>([])
const loading = ref(true)
const loadError = ref('')
const actionError = ref('')
const search = ref('')
const selectedPath = ref<string | null>(null)
const editing = ref(false)
const draft = ref('')
const saving = ref(false)

const filteredFiles = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return files.value
  return files.value.filter(memoryFile =>
    memoryFile.path.toLowerCase().includes(needle)
  )
})

const tree = computed(() => buildTree(filteredFiles.value))

const selected = computed(
  () =>
    files.value.find(memoryFile => memoryFile.path === selectedPath.value) ??
    null
)

const rendered = computed(() =>
  selected.value ? renderMarkdown(selected.value.body ?? '', () => null) : ''
)

const selectedMeta = computed(() => {
  if (!selected.value) return ''
  return `${selected.value.tool} · ${selected.value.size} bytes · ${formatDateTime(selected.value.updated_at)}`
})

async function load() {
  loading.value = true
  loadError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory?include=body')
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    files.value = json.data
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

function select(node: TreeNode) {
  if (!node.file) return
  selectedPath.value = node.file.path
  editing.value = false
}

function startEdit() {
  if (!selected.value) return
  draft.value = selected.value.body ?? ''
  editing.value = true
}

async function save() {
  if (!selected.value) return
  saving.value = true
  actionError.value = ''
  try {
    const res = await props.ctx.api.fetch('/api/agent_memory', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        files: [{ path: selected.value.path, body: draft.value }]
      })
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    const manifest: MemoryFile = json.data[0]
    Object.assign(selected.value, manifest, { body: draft.value })
    editing.value = false
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = false
  }
}

async function remove() {
  if (!selected.value) return
  const ok = await props.ctx.confirm.ask({
    title: 'Delete file',
    message: `Delete ${selected.value.path}? Agents will not pull it any more.`,
    confirmLabel: 'Delete',
    danger: true
  })
  if (!ok) return
  actionError.value = ''
  const path = selected.value.path
  try {
    const res = await props.ctx.api.fetch(
      `/api/agent_memory?path=${encodeURIComponent(path)}`,
      { method: 'DELETE' }
    )
    if (!res.ok) {
      actionError.value = `HTTP ${res.status}`
      return
    }
    files.value = files.value.filter(memoryFile => memoryFile.path !== path)
    selectedPath.value = null
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err)
  }
}

onMounted(load)
</script>

<template>
  <div class="agent-memory">
    <aside class="tree">
      <input
        v-model="search"
        type="search"
        class="search"
        placeholder="Filter by path"
        aria-label="Filter files by path"
        autofocus
      />
      <p v-if="loading" class="muted">Loading…</p>
      <p v-else-if="loadError" class="error">{{ loadError }}</p>
      <p v-else-if="tree.length === 0" class="muted">
        No files yet. Run the servant-memory skill's push script from a repo.
      </p>
      <ul v-else class="nodes">
        <li v-for="node in tree" :key="node.path">
          <MemoryTreeNode
            :node="node"
            :selected-path="selectedPath"
            @select="select"
          />
        </li>
      </ul>
    </aside>

    <section v-if="selected" class="viewer">
      <header class="viewer-head">
        <div>
          <h2 class="path">{{ selected.path }}</h2>
          <p class="muted">{{ selectedMeta }}</p>
        </div>
        <div class="actions">
          <template v-if="editing">
            <button
              type="button"
              class="btn"
              :disabled="saving"
              @click="editing = false"
            >
              Cancel
            </button>
            <button
              type="button"
              class="btn btn--primary"
              :disabled="saving"
              @click="save"
            >
              Save
            </button>
          </template>
          <template v-else>
            <button type="button" class="btn" @click="startEdit">Edit</button>
            <button type="button" class="btn btn--danger" @click="remove">
              Delete
            </button>
          </template>
        </div>
      </header>
      <p v-if="actionError" class="error">{{ actionError }}</p>
      <textarea
        v-if="editing"
        v-model="draft"
        class="editor"
        aria-label="File body"
        spellcheck="false"
      />
      <!-- eslint-disable-next-line vue/no-v-html: markdown rendered by the shared Notes renderer, which escapes user data -->
      <article v-else class="markdown" v-html="rendered" />
    </section>
    <section v-else class="viewer viewer--empty">
      <p class="muted">Select a file.</p>
    </section>
  </div>
</template>

<style scoped>
.agent-memory {
  display: grid;
  grid-template-columns: minmax(220px, 300px) 1fr;
  gap: 1rem;
  height: 100%;
  min-height: 0;
}

@media (max-width: 800px) {
  .agent-memory {
    grid-template-columns: 1fr;
  }
}

.muted {
  color: var(--text-muted);
  font-size: 0.85rem;
}

.error {
  color: var(--danger);
}

/* ----- Tree ----- */
.tree {
  overflow: auto;
  border-right: 1px solid var(--border);
  padding-right: 0.5rem;
}

.search {
  width: 100%;
  box-sizing: border-box;
  margin-bottom: 0.5rem;
  padding: 0.4rem 0.6rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font: inherit;
}

.tree > .nodes {
  list-style: none;
  margin: 0;
  padding-left: 0;
}

/* ----- Viewer ----- */
.viewer {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: auto;
}

.viewer--empty {
  align-items: center;
  justify-content: center;
}

.viewer-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  margin-bottom: 0.75rem;
}

.path {
  margin: 0;
  font-family: var(--font-mono);
  font-size: 1rem;
  word-break: break-all;
}

.actions {
  display: flex;
  gap: 0.5rem;
  flex-shrink: 0;
}

.btn {
  padding: 0.35rem 0.75rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font: inherit;
  cursor: pointer;
}

.btn--primary {
  background: var(--primary);
  border-color: var(--primary);
  color: var(--primary-contrast);
}

.btn--danger {
  color: var(--danger);
}

.editor {
  flex: 1;
  min-height: 60vh;
  padding: 0.75rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-mono);
  font-size: 0.9rem;
  resize: vertical;
}

.markdown {
  line-height: 1.55;
}

.markdown :deep(pre) {
  overflow-x: auto;
  padding: 0.75rem;
  border-radius: 6px;
  background: var(--bg-hover);
}

.markdown :deep(code) {
  font-family: var(--font-mono);
  font-size: 0.9em;
}
</style>
